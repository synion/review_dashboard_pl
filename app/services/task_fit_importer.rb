# Czyta task_fit.json zapisany przez świeżą sesję zgodności z zadaniem i zamienia
# go na werdykt plus znaleziska. Werdykt liczymy TU, z samych statusów - model bywa
# niespójny (statusy mówią „unmet”, a werdykt „fits”), a bramka ma być deterministyczna.
#
# Domyślne jest czerwone: punkt bez odpowiedzi albo ze statusem spoza słownika
# dostaje najgorszy status. To sedno całej zmiany - review 116 przeszło, bo sesja
# mogła pułapkę z zadania po prostu pominąć. Tu pominięcie = otwarta pułapka.
class TaskFitImporter
  Missing = Class.new(StandardError)
  FILENAME = "task_fit.json"

  # kind → [dozwolone statusy, status domyślny przy braku odpowiedzi]
  RULES = {
    "criterion" => [ %w[met unmet unverifiable], "unverifiable" ],
    "trap" => [ %w[addressed open], "open" ],
    "process" => [ %w[present missing n/a], "missing" ]
  }.freeze
  # Statusy, które same w sobie zamykają zadanie na czerwono.
  BLOCKING = %w[unmet open missing].freeze
  NO_ANSWER = "sesja nie odpowiedziała na ten punkt".freeze
  TITLE_WORDS = 12
  # Treść znaleziska per status czerwony/żółty. `fix` to fallback - gdy sesja podała
  # needed_evidence, ono wygrywa (mówi, co konkretnie zdobyć).
  TEMPLATES = {
    "unmet" => { priority: "critical", title: "AC niespełnione",
                 consequence: "Zadanie zostanie zamknięte, choć to kryterium nie jest zrealizowane.",
                 fix: "Zrealizować to kryterium w tym PR-ze albo jawnie wyłączyć je z zakresu w zadaniu." },
    "open" => { priority: "critical", title: "Pułapka z zadania otwarta",
                consequence: "Ryzyko opisane w zadaniu przechodzi do produkcji bez sprawdzenia.",
                fix: "Autor ma odnieść się do tej pułapki na PR-ze albo w zadaniu, z dowodem." },
    "missing" => { priority: "critical", title: "Brak w procesie",
                   consequence: "Zmiana powstaje bez elementu, którego proces zespołu wymaga przed implementacją.",
                   fix: "Uzupełnić brakujący element procesu w zadaniu, zanim PR pójdzie dalej." },
    "unverifiable" => { priority: "important", title: "Niesprawdzalne z kodu",
                        consequence: "Nikt nie wie, czy to kryterium jest spełnione - kod tego nie rozstrzyga.",
                        fix: "Poprosić autora o dowód spoza kodu (log, zrzut z panelu, repro) i dołączyć go do zadania." }
  }.freeze

  def self.call(review)
    path = review.artifacts_dir.join(FILENAME)
    raise Missing, "Sesja nie zapisała #{path} - ocena zgodności niedokończona" unless File.exist?(path)

    import(review, JSON.parse(File.read(path)))
  end

  def self.import(review, data)
    new(review, data).import
  end

  def initialize(review, data)
    @review = review
    @data = data
  end

  def import
    items = merged_items
    evidence_found = @data["evidence_found"] == true
    result = { "symptom" => @data["symptom"], "assumed_cause" => @data["assumed_cause"], "evidence" => @data["evidence"],
               "evidence_found" => evidence_found,
               "criteria" => items.select { |i| i["kind"] == "criterion" },
               "traps" => items.select { |i| i["kind"] == "trap" },
               "process" => items.select { |i| i["kind"] == "process" },
               "verdict" => verdict_for(items, evidence_found) }

    @review.transaction do
      @review.findings.from_task_fit.destroy_all
      findings_for(items, result).each { |attrs| @review.findings.create!(attrs.merge(source: "task_fit")) }
      @review.update!(task_fit: result, task_fit_status: "ready", task_fit_checked_at: Time.current)
    end
  end

  private

  # Znane punkty (z task_criteria) łączymy z odpowiedziami sesji po id. Nieznane id
  # pomijamy (model wymyślił punkt), brak odpowiedzi = status domyślny, czyli czerwony.
  def merged_items
    answers = Review::TASK_FIT_SECTIONS.keys.flat_map { |key| Array(@data[key]) }.index_by { |a| a["id"].to_s }
    @review.task_criteria_list.map do |item|
      allowed, default = RULES.fetch(item["kind"])
      answer = answers[item["id"].to_s] || {}
      answered = allowed.include?(answer["status"])
      item.merge("status" => answered ? answer["status"] : default,
                 "note" => answered ? answer["note"].to_s : NO_ANSWER,
                 "needed_evidence" => answer["needed_evidence"].presence).compact
    end
  end

  def verdict_for(items, evidence_found)
    return "misses" if !evidence_found || items.any? { |i| BLOCKING.include?(i["status"]) }
    return "partial" if items.any? { |i| i["status"] == "unverifiable" }

    "fits"
  end

  def findings_for(items, result)
    findings = items.filter_map { |item| finding_for(item) }
    findings.unshift(premise_finding(result)) unless result["evidence_found"]
    findings
  end

  def finding_for(item)
    template = TEMPLATES[item["status"]] or return

    { priority: template[:priority],
      title: "#{template[:title]}: #{item["text"].to_s.split.first(TITLE_WORDS).join(" ")}",
      body: body(item["note"], template[:consequence], item["needed_evidence"] || template[:fix]) }
  end

  def premise_finding(result)
    { priority: "critical", title: "Przyczyna z PR-a jest hipotezą bez dowodu",
      body: body("PR zakłada przyczynę „#{result["assumed_cause"]}” dla objawu „#{result["symptom"]}”, " \
                 "ale w zadaniu ani na PR-ze nie ma dowodu, że to ta przyczyna.",
                 "Poprawka może być poprawna technicznie i nie zmienić nic dla zgłaszającego.",
                 result["evidence"].presence || "Autor ma dołączyć do zadania dowód na przyczynę (log, repro, odpowiedź systemu).") }
  end

  def body(problem, consequence, fix)
    "**Problem:** #{problem}\n\n**Co się stanie:** #{consequence}\n\n**Jak naprawić:** #{fix}"
  end
end
