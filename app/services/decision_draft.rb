# Szkice treści decyzji - osobny dla każdego werdyktu, bo ten sam materiał
# (werdykt zgodności, statusy punktów z zadania, znaleziska) znaczy co innego
# w zależności od tego, co reviewer chce autorowi powiedzieć:
#   approve - „biorę na siebie” niespełnione punkty, uwagi są nieblokujące;
#   reject  - punkty i znaleziska są listą do poprawy;
#   comment - luki zamieniają się w pytania, bez werdyktu.
# Bez tego jedna wspólna treść pod trzema przyciskami czytała się na GitHubie
# identycznie, niezależnie od tego, czy PR przeszedł, czy nie.
#
# Szkic jest deterministyczny (bez sesji AI): dane już są, a user i tak edytuje
# tekst przed wysłaniem. Punkty z zadania bierzemy z task_fit_items, a NIE ze
# znalezisk task_fit - te same fakty leżą w obu miejscach i wyszłyby podwójnie.
class DecisionDraft
  BLOCKING_PRIORITIES = %w[critical important].freeze

  def initialize(review)
    @review = review
  end

  def all = Review::DECISIONS.index_with { |verdict| self.for(verdict) }

  def for(verdict)
    sections = header + send(:"#{verdict}_sections")
    sections.compact.join("\n\n").strip + "\n"
  end

  # Zakładka, którą formularz otwiera na starcie. Czerwone albo blokujące
  # znalezisko z kodu - reject; żółte (niesprawdzalne z kodu) - comment, bo tam
  # jest pytanie do autora; reszta - approve. Tylko podpowiedź: user przełącza.
  def suggested_verdict
    return "reject" if @review.task_fit_verdict == "misses" || blocking_findings.any?
    return "comment" if unverifiable_items.any?

    "approve"
  end

  private

  def header
    parts = [ "## Review" ]
    parts << "**Zgodność z zadaniem:** #{@review.task_fit_label}" if @review.task_fit_verdict
    parts << @review.summary.to_s.strip.presence
    parts
  end

  def approve_sections
    [ list("**Zatwierdzam mimo niespełnionych punktów z zadania** (świadoma decyzja):", blocking_items) { |item| item_line(item) },
      list("**Niesprawdzone z kodu** (do potwierdzenia poza PR-em):", unverifiable_items) { |item| evidence_line(item) },
      list("**Uwagi nieblokujące** (nie wstrzymują merge'a):", code_findings) { |finding| finding_line(finding) } ]
  end

  def reject_sections
    [ "**Proszę o zmiany przed merge'em.**",
      list("**Niespełnione punkty z zadania:**", blocking_items) { |item| item_line(item) },
      list("**Do poprawy:**", blocking_findings) { |finding| finding_line(finding) },
      list("**Do wykazania** (kod tego nie rozstrzyga):", unverifiable_items) { |item| evidence_line(item) },
      list("**Drobne** (opcjonalnie):", minor_findings) { |finding| finding_line(finding) } ]
  end

  def comment_sections
    [ "**Bez werdyktu - mam pytania, zanim zdecyduję.**",
      list("**Pytania do autora:**", unverifiable_items) { |item| "#{item["text"]} - jak to sprawdzić?#{" Potrzebne: #{item["needed_evidence"]}" if item["needed_evidence"].present?}" },
      list("**Do wyjaśnienia:**", blocking_items) { |item| "#{item["text"]} - czy to świadomie poza zakresem tego PR-a?#{note_suffix(item)}" },
      list("**Uwagi do przemyślenia:**", code_findings) { |finding| finding_line(finding) } ]
  end

  def list(title, entries)
    return nil if entries.empty?

    ([ title ] + entries.map { |entry| "- #{yield(entry)}" }).join("\n")
  end

  def item_line(item) = "#{item["text"]}#{note_suffix(item)}"

  def evidence_line(item)
    "#{item["text"]}#{item["needed_evidence"].present? ? " - potrzebne: #{item["needed_evidence"]}" : note_suffix(item)}"
  end

  def note_suffix(item) = item["note"].present? ? " (#{item["note"]})" : ""

  def finding_line(finding)
    location = finding.file_location.present? ? " (#{finding.file_location})" : ""
    "**[#{finding.priority}]** #{finding.title}#{location}"
  end

  def blocking_items = items.select { |item| Review.task_fit_status_blocking?(item["status"]) }

  def unverifiable_items = items.select { |item| Review.task_fit_status_unverifiable?(item["status"]) }

  # Bez wyniku sesji punkty nie mają statusu, więc obie listy wyżej są puste same z siebie.
  def items
    @items ||= @review.task_fit_items
  end

  def blocking_findings = code_findings.select { |finding| BLOCKING_PRIORITIES.include?(finding.priority) }

  def minor_findings = code_findings.reject { |finding| BLOCKING_PRIORITIES.include?(finding.priority) }

  # order(:priority) alfabetycznie daje critical < important < minor - to jest
  # kolejność, o którą chodzi.
  def code_findings
    @code_findings ||= @review.findings.from_review.order(:priority, :id).to_a
  end
end
