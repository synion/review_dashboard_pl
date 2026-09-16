# Prefill wiadomości do sesji followupu - inny po każdym werdykcie, bo „sprawdź
# poprawki" po reject znaczy „czy wymagane zmiany weszły", po approve „co doszło
# od zatwierdzenia", a po comment „czy autor odpowiedział na pytania". Dwie
# rodziny: zwykłe ponowne sprawdzenie i konfrontacja z podważeniem decyzji.
# Dane te same co w szkicu decyzji (DecisionDraft#placeholders) plus decyzja.
class FollowupMessage
  PLACEHOLDERS = DecisionDraft::PLACEHOLDERS.merge(
    "decision" => "werdykt decyzji (approve / reject / comment)",
    "decided_at" => "data i godzina decyzji", "task_url" => "adres zadania w trackerze"
  ).freeze

  FOLLOWUP_DEFAULTS = {
    "approve" => <<~MUSTACHE,
      Zatwierdziłem PR ({{decided_at}}), a od tego czasu coś się zmieniło - pobierz najnowszy stan brancha (git pull) i sprawdź, co doszło po moim approve i czy PR nadal na niego zasługuje.
      {{#findings_list}}

      Uwagi nieblokujące z mojego review - sprawdź, czy autor je uwzględnił:
      {{findings_list}}
      {{/findings_list}}
      {{#unverifiable_list}}

      Punkty, których nie dało się sprawdzić z kodu - czy pojawił się dowód?
      {{unverifiable_list}}
      {{/unverifiable_list}}
    MUSTACHE
    "reject" => <<~MUSTACHE,
      Po moim reject ({{decided_at}}) doszły poprawki - pobierz najnowszy stan brancha (git pull) i sprawdź, czy KAŻDA wymagana zmiana została wdrożona, a nie tylko część.
      {{#blocking_findings_list}}

      Wymagane zmiany:
      {{blocking_findings_list}}
      {{/blocking_findings_list}}
      {{#blocking_list}}

      Niespełnione punkty z zadania - czy są już zamknięte?
      {{blocking_list}}
      {{/blocking_list}}
      {{#minor_findings_list}}

      Drobne (opcjonalne):
      {{minor_findings_list}}
      {{/minor_findings_list}}
    MUSTACHE
    "comment" => <<~MUSTACHE
      Zadałem pytania bez werdyktu ({{decided_at}}) - pobierz najnowszy stan brancha (git pull), przeczytaj odpowiedzi autora na PR-ze i sprawdź, czy rozstrzygają wątpliwości; jeśli kod się zmienił, oceń zmiany.
      {{#unverifiable_questions}}

      Pytania:
      {{unverifiable_questions}}
      {{/unverifiable_questions}}
      {{#blocking_questions}}

      Do wyjaśnienia:
      {{blocking_questions}}
      {{/blocking_questions}}
      {{#findings_list}}

      Uwagi do przemyślenia:
      {{findings_list}}
      {{/findings_list}}
    MUSTACHE
  }.freeze

  CHALLENGE_PLACEHOLDERS = PLACEHOLDERS.merge(
    "challenge" => "kto i gdzie podważył decyzję, z instrukcją, co przeczytać",
    "challenge_by" => "login podważającego (przy podważeniu na PR-ze)"
  ).freeze

  CHALLENGE_DEFAULTS = {
    "approve" => <<~MUSTACHE,
      {{challenge}} Skonfrontuj to z moim approve ({{decided_at}}) i odpowiedz wprost: czy PR zasługiwał na approve, co przeoczyłem i czy PR w ogóle rozwiązuje zgłoszenie z zadania. Nie broń poprzedniego wniosku - sprawdź go od nowa.
    MUSTACHE
    "reject" => <<~MUSTACHE,
      {{challenge}} Skonfrontuj to z moimi wymaganiami zmian ({{decided_at}}) i odpowiedz wprost: czy były zasadne, czy podważający ma rację i czy PR w ogóle rozwiązuje zgłoszenie z zadania. Nie broń poprzedniego wniosku - sprawdź go od nowa.
      {{#blocking_findings_list}}

      Moje wymagania:
      {{blocking_findings_list}}
      {{/blocking_findings_list}}
    MUSTACHE
    "comment" => <<~MUSTACHE
      {{challenge}} Skonfrontuj to z moimi pytaniami ({{decided_at}}) i odpowiedz wprost: czy zostały odpowiedziane, czy podważający wnosi coś nowego i czy PR w ogóle rozwiązuje zgłoszenie z zadania. Nie broń poprzedniego wniosku - sprawdź go od nowa.
      {{#unverifiable_questions}}

      Moje pytania:
      {{unverifiable_questions}}
      {{/unverifiable_questions}}
    MUSTACHE
  }.freeze

  FOLLOWUP = MessageTemplate::Family.new(
    key: "followup", label: "Wiadomość ponownego sprawdzenia poprawek",
    hint: "Prefill pola „Sprawdź poprawki” po decyzji (statusy: czeka ponowne review, zdecydowany).",
    defaults: FOLLOWUP_DEFAULTS, placeholders: PLACEHOLDERS
  )
  CHALLENGE = MessageTemplate::Family.new(
    key: "challenge", label: "Wiadomość po podważeniu decyzji",
    hint: "Prefill konfrontacji, gdy ktoś zażądał zmian na PR-ze albo w zadaniu doszły komentarze po decyzji.",
    defaults: CHALLENGE_DEFAULTS, placeholders: CHALLENGE_PLACEHOLDERS
  )

  def initialize(review)
    @review = review
  end

  def check_fixes = MessageTemplate.render_for(@review.project, "followup", verdict, placeholders)

  def challenge = MessageTemplate.render_for(@review.project, "challenge", verdict, placeholders.merge(challenge_placeholders))

  private

  # Statusy z followupem mają decyzję; brak (spreparowany stan) traktujemy jak reject -
  # najostrożniejszy wariant, bo każe sprawdzić wszystko.
  def verdict = @review.decision || "reject"

  def placeholders
    @placeholders ||= DecisionDraft.new(@review).placeholders.merge(
      decision: @review.decision, decided_at: @review.decided_at&.strftime("%Y-%m-%d %H:%M"),
      task_url: @review.task_url.presence
    )
  end

  # Źródło podważenia niesie własną instrukcję, co przeczytać - werdykt dokłada
  # tylko, z czym to skonfrontować.
  def challenge_placeholders
    challenge = @review.challenge || {}
    sentence = if challenge["source"] == "task"
      "W zadaniu #{@review.task_url} pojawiły się nowe komentarze po mojej decyzji - otwórz zadanie i przeczytaj WSZYSTKIE komentarze dodane po #{placeholders[:decided_at]}."
    else
      "Inny reviewer (#{challenge["by"]}) zażądał zmian po mojej decyzji - przeczytaj jego review w sekcji „Cudze review pod PR-em”."
    end
    { challenge: sentence, challenge_by: challenge["by"] }
  end
end
