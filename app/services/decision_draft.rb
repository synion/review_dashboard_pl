# Szkice treści decyzji - osobny dla każdego werdyktu, bo ten sam materiał
# (werdykt zgodności, statusy punktów z zadania, znaleziska) znaczy co innego
# w zależności od tego, co reviewer chce autorowi powiedzieć:
#   approve - „biorę na siebie” niespełnione punkty, uwagi są nieblokujące;
#   reject  - punkty i znaleziska są listą do poprawy;
#   comment - luki zamieniają się w pytania, bez werdyktu.
#
# Kształt każdego szkicu to szablon Mustache: projekt może go nadpisać
# (Project#template("decision", werdykt)), a DEFAULT_TEMPLATES są punktem wyjścia. Dane
# wchodzą jako gotowe kawałki markdownu (PLACEHOLDERS) - listy przychodzą jako
# nil, gdy są puste, żeby blok {{#lista}}…{{/lista}} zniknął razem z nagłówkiem.
# Punkty z zadania bierzemy z task_fit_items, a NIE ze znalezisk task_fit -
# te same fakty leżą w obu miejscach i wyszłyby podwójnie.
class DecisionDraft
  BLOCKING_PRIORITIES = %w[critical important].freeze

  # Nazwa → opis do podpowiedzi w formularzu projektu. Wszystkie wartości to
  # tekst albo nil; listy są już złożone z linii „- …".
  PLACEHOLDERS = {
    "summary" => "pełne podsumowanie review z sesji",
    "summary_short" => "pierwszy akapit podsumowania (linia „Krótko:”)",
    "summary_rest" => "podsumowanie bez pierwszego akapitu (puste, gdy jest tylko „Krótko:”)",
    "task_fit" => "werdykt zgodności z zadaniem (np. „Rozwiązuje zadanie”)",
    "pr_title" => "tytuł PR-a", "task_title" => "tytuł zadania z trackera", "branch" => "nazwa brancha",
    "blocking_list" => "niespełnione punkty z zadania, z notatką sesji",
    "blocking_questions" => "te same punkty jako pytania „czy to świadomie poza zakresem?”",
    "unverifiable_list" => "punkty niesprawdzalne z kodu, z tym, co trzeba zdobyć",
    "unverifiable_questions" => "te same punkty jako pytania „jak to sprawdzić?”",
    "findings_list" => "wszystkie uwagi do kodu (priorytet, tytuł, plik)",
    "blocking_findings_list" => "uwagi krytyczne i ważne",
    "minor_findings_list" => "uwagi drobne"
  }.freeze

  # Werdykt idzie pierwszy (nagłówek i zdanie), potem „Krótko:", potem sekcje
  # zależne od werdyktu, a pełne podsumowanie sesji na końcu w zwijanym bloku -
  # inaczej ta sama ściana tekstu na górze każdej zakładki przykrywała różnice.
  HEADER = <<~MUSTACHE
    {{#task_fit}}

    **Zgodność z zadaniem:** {{task_fit}}
    {{/task_fit}}
    {{#summary_short}}

    {{summary_short}}
    {{/summary_short}}

  MUSTACHE
  FOOTER = <<~MUSTACHE
    {{#summary_rest}}

    <details><summary>Pełne podsumowanie review</summary>

    {{summary}}

    </details>
    {{/summary_rest}}
  MUSTACHE

  DEFAULT_TEMPLATES = {
    "approve" => "## ✅ Approve\n" + HEADER + <<~MUSTACHE + FOOTER,
      **Zatwierdzam - nie wstrzymuję merge'a.**
      {{#blocking_list}}

      **Świadomie mimo niespełnionych punktów z zadania:**
      {{blocking_list}}
      {{/blocking_list}}
      {{#unverifiable_list}}

      **Niesprawdzone z kodu** (do potwierdzenia poza PR-em):
      {{unverifiable_list}}
      {{/unverifiable_list}}
      {{#findings_list}}

      **Uwagi nieblokujące** (nie wstrzymują merge'a):
      {{findings_list}}
      {{/findings_list}}
    MUSTACHE
    "reject" => "## ❌ Reject - wymagane zmiany\n" + HEADER + <<~MUSTACHE + FOOTER,
      **Proszę o zmiany przed merge'em.**
      {{#blocking_list}}

      **Niespełnione punkty z zadania:**
      {{blocking_list}}
      {{/blocking_list}}
      {{#blocking_findings_list}}

      **Do poprawy:**
      {{blocking_findings_list}}
      {{/blocking_findings_list}}
      {{#unverifiable_list}}

      **Do wykazania** (kod tego nie rozstrzyga):
      {{unverifiable_list}}
      {{/unverifiable_list}}
      {{#minor_findings_list}}

      **Drobne** (opcjonalnie):
      {{minor_findings_list}}
      {{/minor_findings_list}}
    MUSTACHE
    "comment" => "## 💬 Comment - pytania przed decyzją\n" + HEADER + <<~MUSTACHE + FOOTER
      **Bez werdyktu - mam pytania, zanim zdecyduję.**
      {{#unverifiable_questions}}

      **Pytania do autora:**
      {{unverifiable_questions}}
      {{/unverifiable_questions}}
      {{#blocking_questions}}

      **Do wyjaśnienia:**
      {{blocking_questions}}
      {{/blocking_questions}}
      {{#findings_list}}

      **Uwagi do przemyślenia:**
      {{findings_list}}
      {{/findings_list}}
    MUSTACHE
  }.freeze

  FAMILY = MessageTemplate::Family.new(
    key: "decision", label: "Treść decyzji na GitHub",
    hint: "Szkic w zakładce decyzji - user edytuje go przed wysłaniem.",
    defaults: DEFAULT_TEMPLATES, placeholders: PLACEHOLDERS
  )

  def initialize(review)
    @review = review
  end

  def all = Review::DECISIONS.index_with { |verdict| self.for(verdict) }

  def for(verdict) = MessageTemplate.render_for(@review.project, "decision", verdict, placeholders) + "\n"

  # Zakładka, którą formularz otwiera na starcie. Czerwone albo blokujące
  # znalezisko z kodu - reject; żółte (niesprawdzalne z kodu) - comment, bo tam
  # jest pytanie do autora; reszta - approve. Tylko podpowiedź: user przełącza.
  def suggested_verdict
    return "reject" if @review.task_fit_verdict == "misses" || blocking_findings.any?
    return "comment" if unverifiable_items.any?

    "approve"
  end

  # Wartości pod nazwy z PLACEHOLDERS - publiczne, bo wiadomości followupu
  # (FollowupMessage) mówią o tych samych punktach i znaleziskach.
  def placeholders
    @placeholders ||= begin
      blocking, unverifiable = blocking_items, unverifiable_items
      summary = @review.summary.to_s.strip.presence
      short, rest = summary.to_s.split(/\n[ \t]*\n/, 2).map { |part| part.to_s.strip.presence }
      { summary: summary, summary_short: short, summary_rest: rest,
        task_fit: (@review.task_fit_label if @review.task_fit_verdict),
        pr_title: @review.pr_title.presence, task_title: @review.task_title.presence, branch: @review.branch.presence,
        blocking_list: lines(blocking) { |item| item_line(item) },
        blocking_questions: lines(blocking) { |item| "#{item["text"]} - czy to świadomie poza zakresem tego PR-a?#{note_suffix(item)}" },
        unverifiable_list: lines(unverifiable) { |item| evidence_line(item) },
        unverifiable_questions: lines(unverifiable) { |item| "#{item["text"]} - jak to sprawdzić?#{" Potrzebne: #{item["needed_evidence"]}" if item["needed_evidence"].present?}" },
        findings_list: lines(code_findings) { |finding| finding_line(finding) },
        blocking_findings_list: lines(blocking_findings) { |finding| finding_line(finding) },
        minor_findings_list: lines(minor_findings) { |finding| finding_line(finding) } }
    end
  end

  private

  # presence, bo w Mustache „" jest prawdą i blok z nagłówkiem by został.
  def lines(entries) = entries.map { |entry| "- #{yield(entry)}" }.join("\n").presence

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
