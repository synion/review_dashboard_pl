require "test_helper"

class PromptBuilderTest < ActiveSupport::TestCase
  test "describe dla PR zawiera link do PR i szkielet opisu" do
    prompt = PromptBuilder.describe(reviews(:pr_review))
    assert_includes prompt, "https://github.com/acme/webapp/pull/1234"
    assert_includes prompt, "**Krótko:**"
    assert_includes prompt, "**Na co uważać**"
  end

  # Szablon, który zapomni o `<%= style %>`, wraca ze ścianą tekstu — nie do przeczytania
  # dla usera. Sprawdzamy cały katalog, żeby przyszły prompt nie prześlizgnął się bez zasad.
  # Partiale (`_*.md.erb`) są wstawiane do promptów, nie renderowane samodzielnie.
  test "każdy szablon promptu wstawia wspólne zasady pisania" do
    templates = Dir.glob(PromptBuilder::TEMPLATES_DIR.join("*.md.erb"))
                   .reject { |path| File.basename(path).start_with?("_") }
    assert_equal 10, templates.size
    templates.each do |path|
      assert_includes File.read(path), "<%= style %>", "#{File.basename(path)} nie wstawia zasad pisania"
    end
  end

  test "wyrenderowany prompt niesie treść zasad" do
    prompt = PromptBuilder.followup(reviews(:pr_review), "to false positive", resumed: true)
    assert_includes prompt, "osoba z ADHD"
    assert_includes prompt, "Max 15 słów"
  end

  test "review dostaje opis zadania i każe konfrontować kod z AC, gdy opis jest" do
    review = reviews(:pr_review)
    review.update!(task_description: "**Cel** — rabaty działają.\n\n**Acceptance Criteria**\n- [ ] rabat 10%")
    prompt = PromptBuilder.review(review)
    assert_includes prompt, "Opis zadania"
    assert_includes prompt, "rabat 10%"
    assert_includes prompt, "Acceptance Criteria"
  end

  test "review bez opisu zadania nie niesie pustej sekcji o nim" do
    assert_not_includes PromptBuilder.review(reviews(:pr_review)), "Opis zadania"
  end

  test "review dostaje zarys zmian z describe, gdy jest" do
    review = reviews(:pr_review)
    review.update!(description: "**Krótko:** rabaty w koszyku.")
    prompt = PromptBuilder.review(review)
    assert_includes prompt, "zarys zmian"
    assert_includes prompt, "rabaty w koszyku"
  end

  test "review bez opisu zmian nie niesie pustej sekcji o nim" do
    assert_not_includes PromptBuilder.review(reviews(:pr_review)), "zarys zmian"
  end

  test "kontekst po zmianie konta niesie też opis zadania" do
    review = reviews(:pr_review)
    review.update!(claude_config: "/Users/dev/.claude-b",
                   task_description: "**Cel** — rabaty działają.")
    review.claude_runs.create!(kind: "review", claude_config: "/Users/dev/.claude",
                               status: "succeeded", session_id: "s1")
    prompt = PromptBuilder.review(review)
    assert_includes prompt, "rabaty działają"
  end

  test "review narzuca szkielet summary i trzech pól znaleziska" do
    prompt = PromptBuilder.review(reviews(:pr_review))
    assert_includes prompt, "**Co sprawdziłem**"
    assert_includes prompt, "**Problem:**"
    assert_includes prompt, "**Co się stanie:**"
    assert_includes prompt, "**Jak naprawić:**"
  end

  # Kontrola zakresu i prostoty ma iść w każdym review, także takim, w którym reviewer
  # odklikał obszary — inaczej „autor zrobił za dużo" wypada z review razem z Czytelnością.
  test "review zawsze każe sprawdzić zakres zmiany i prostszą wersję" do
    review = reviews(:pr_review)
    review.update!(scope: { "areas" => [ "functionality" ] })
    prompt = PromptBuilder.review(review)
    assert_includes prompt, "## Zakres i prostota (obowiązkowe)"
    assert_includes prompt, "Czy zmiana nie jest za szeroka?"
    assert_includes prompt, "Czy tego samego nie da się zrobić dużo prościej?"
    assert_includes prompt, "**Zakres i prostota** — jedno zdanie"
  end

  test "weryfikacja uwag wie, jak oceniać uwagi o zakresie i prostocie" do
    prompt = PromptBuilder.verify_findings(reviews(:pr_review))
    assert_includes prompt, "Uwagi o zakresie i prostocie"
  end

  test "describe_task z linkiem każe czytać zadanie i komentarze" do
    prompt = PromptBuilder.describe_task(reviews(:task_only))
    assert_includes prompt, "https://tasks.example.com/555"
    assert_includes prompt, "komentarz"
    assert_includes prompt, "TASK_URL:"
    assert_includes prompt, "**Acceptance Criteria**"
  end

  test "describe_task każe zapisać task_criteria.json z AC, pułapkami i wymogami procesu" do
    review = reviews(:task_only)
    review.project.update!(process_rules: "Nowy feature: link do Figmy w zadaniu.")
    prompt = PromptBuilder.describe_task(review)
    assert_includes prompt, review.artifacts_dir.join("task_criteria.json").to_s
    assert_includes prompt, '"criteria"'
    assert_includes prompt, '"traps"'
    assert_includes prompt, '"process"'
    assert_includes prompt, '"id": "ac1"'
    assert_includes prompt, "Nowy feature: link do Figmy w zadaniu."
    assert_includes prompt, "Wymogi procesu"
  end

  test "describe_task bez wymogów procesu nie niesie pustej sekcji o nich" do
    prompt = PromptBuilder.describe_task(reviews(:task_only))
    assert_not_includes prompt, "Wymogi procesu"
    assert_includes prompt, '"process": []'
  end

  test "describe_task bez linku każe szukać go w opisie PR" do
    prompt = PromptBuilder.describe_task(reviews(:pr_review))
    assert_includes prompt, "gh pr view"
    assert_includes prompt, "https://github.com/acme/webapp/pull/1234"
    assert_includes prompt, "TASK_URL: none"
  end

  test "comment_task niesie link, decyzję, instrukcję i kontrakt ERROR" do
    review = reviews(:task_only)
    review.update!(decision: "approve", decision_body: "LGTM, drobiazgi w treści",
                   task_comment_instructions: "Krótko, dla PM-a")
    prompt = PromptBuilder.comment_task(review)
    assert_includes prompt, "https://tasks.example.com/555"
    assert_includes prompt, "approve"
    assert_includes prompt, "LGTM, drobiazgi w treści"
    assert_includes prompt, "Krótko, dla PM-a"
    assert_includes prompt, "ERROR:"
  end

  test "comment_task bez instrukcji nie niesie pustej sekcji o niej" do
    review = reviews(:task_only)
    review.update!(decision: "reject")
    assert_not_includes PromptBuilder.comment_task(review), "Instrukcja"
  end

  test "describe dla zadania bez PR-a wskazuje link do zadania" do
    prompt = PromptBuilder.describe(reviews(:task_only))
    assert_includes prompt, "https://tasks.example.com/555"
  end

  test "review zawiera tylko wybrane obszary, uwagi usera i kontrakt result.json" do
    review = reviews(:pr_review)
    review.update!(scope: { "areas" => %w[functionality qa_playwright], "notes" => "uważaj na VAT" })
    prompt = PromptBuilder.review(review)
    assert_includes prompt, "Funkcjonalność"
    assert_includes prompt, "QA + Playwright"
    assert_not_includes prompt, "Czytelność"
    assert_includes prompt, "uważaj na VAT"
    assert_includes prompt, review.artifacts_dir.join("result.json").to_s
    assert_includes prompt, "spotlight"
  end

  test "review bez qa_playwright nie każe pisać testu" do
    review = reviews(:pr_review)
    review.update!(scope: { "areas" => %w[functionality], "notes" => "" })
    prompt = PromptBuilder.review(review)
    assert_not_includes prompt, "spotlight"
    assert_includes prompt, '"playwright": null'
  end

  # Skill pisany pod pracę z człowiekiem: bez tej sekcji sesja w tle założyłaby drugi
  # worktree, zacommitowała testy, dała approve i napisała w trackerze.
  test "review z obszarami security każe wywołać skille i zakazuje kroków po zgodzie usera" do
    review = reviews(:pr_review)
    review.update!(scope: { "areas" => %w[functionality sec_pr_audit security_review] })
    prompt = PromptBuilder.review(review)
    assert_includes prompt, "## Audyt security (obowiązkowe)"
    assert_includes prompt, "`sec-pr-audit` z argumentem `#{review.pr_url}`"
    assert_includes prompt, "`security-review`"
    assert_includes prompt, "Nie zakładaj\n  drugiego"
    assert_includes prompt, "Po zgodzie usera"
    assert_includes prompt, "**Audyt security** — werdykt:", "wynik audytu ma własny blok w summary"
  end

  test "review bez obszarów security nie wspomina o skillach" do
    review = reviews(:pr_review)
    review.update!(scope: { "areas" => %w[functionality] })
    prompt = PromptBuilder.review(review)
    assert_not_includes prompt, "## Audyt security"
    assert_not_includes prompt, "**Audyt security**"
  end

  test "review dokleja stałe zasady projektu gdy są" do
    review = reviews(:pr_review)
    review.project.update!(review_prompt_extra: "Zawsze sprawdzaj warianty tailwind widoków.")
    review.update!(scope: { "areas" => %w[functionality], "notes" => "" })
    assert_includes PromptBuilder.review(review), "Zawsze sprawdzaj warianty tailwind widoków."
  end

  test "prompt bez zmiany konta nie niesie sekcji kontekstu" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: review.effective_claude_config,
                               status: "succeeded", session_id: "s1")
    assert_not_includes PromptBuilder.review(review), "Kontekst poprzedniego review"
  end

  test "followup wznowionej sesji bez zmiany konta nie niesie sekcji kontekstu" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: review.effective_claude_config,
                               status: "succeeded", session_id: "s1")
    prompt = PromptBuilder.followup(review, "to false positive", resumed: true)
    assert_not_includes prompt, "Kontekst poprzedniego review"
    assert_includes prompt, "masz pełny kontekst poprzedniej sesji"
  end

  # Plik sesji potrafi zniknąć bez żadnej zmiany konta (sprzątanie Claude CLI, usunięty
  # worktree zmieniający slug katalogu). Świeża sesja dostaje wtedy prompt każący nadpisać
  # cały result.json — bez kontekstu skasowałaby poprzednie znaleziska, zgadując od zera.
  test "followup świeżą sesją niesie kontekst, choć konto się nie zmieniło" do
    review = reviews(:pr_review)
    review.update!(description: "OPIS ZADANIA", summary: "STARE PODSUMOWANIE")
    review.claude_runs.create!(kind: "review", claude_config: review.effective_claude_config,
                               status: "succeeded", session_id: "s1")
    prompt = PromptBuilder.followup(review, "to false positive", resumed: false)
    assert_includes prompt, "Kontekst poprzedniego review"
    assert_includes prompt, "STARE PODSUMOWANIE"
    assert_not_includes prompt, "masz pełny kontekst poprzedniej sesji"
  end

  test "po zmianie konta review dostaje opis zadania i poprzedni wynik" do
    review = reviews(:pr_review)
    review.update!(claude_config: "/Users/dev/.claude-b",
                   description: "OPIS ZADANIA", summary: "STARE PODSUMOWANIE")
    review.findings.create!(priority: "critical", title: "Nil na kwocie", body: "x", file_location: "app/x.rb:1")
    review.claude_runs.create!(kind: "review", claude_config: "/Users/dev/.claude",
                               status: "succeeded", session_id: "s1")
    prompt = PromptBuilder.review(review)
    assert_includes prompt, "Kontekst poprzedniego review"
    assert_includes prompt, "Konto Claude zmieniło się"
    assert_includes prompt, "OPIS ZADANIA"
    assert_includes prompt, "STARE PODSUMOWANIE"
    assert_includes prompt, "Nil na kwocie"
  end

  test "followup po zmianie konta też dostaje kontekst" do
    review = reviews(:pr_review)
    review.update!(claude_config: "/Users/dev/.claude-b", summary: "STARE PODSUMOWANIE")
    review.claude_runs.create!(kind: "review", claude_config: "/Users/dev/.claude",
                               status: "succeeded", session_id: "s1")
    prompt = PromptBuilder.followup(review, "to false positive", resumed: true)
    assert_includes prompt, "Kontekst poprzedniego review"
    assert_includes prompt, "Konto Claude zmieniło się", "sekcja leci nawet przy udanym --resume"
    assert_includes prompt, "STARE PODSUMOWANIE"
    assert_includes prompt, "to false positive"
  end

  # Dokumentacja projektu (doc/llm) to kontekst potrzebny w każdym obszarze review,
  # nie osobny obszar — dlatego sekcja nie zależy od zaznaczonych checkboxów.
  test "review każe przeczytać dokumentację projektu, gdy katalog jest w repo" do
    with_repo(docs: "doc/llm") do |review|
      prompt = PromptBuilder.review(review)
      assert_includes prompt, "Dokumentacja projektu"
      assert_includes prompt, "ls doc/llm/"
    end
  end

  test "projekt bez katalogu dokumentacji nie dostaje sekcji o niej" do
    with_repo(docs: nil) do |review|
      assert_not_includes PromptBuilder.review(review), "Dokumentacja projektu"
    end
  end

  test "ustawiona inna ścieżka dokumentacji trafia do promptu" do
    with_repo(docs: "docs/ai") do |review|
      review.project.update!(docs_path: "docs/ai")
      assert_includes PromptBuilder.review(review), "ls docs/ai/"
    end
  end

  test "przy komentarzach inline prompt wymaga linii obecnej w diffie" do
    review = reviews(:pr_review)
    review.update!(scope: { "areas" => %w[functionality], "inline_comments" => true })
    prompt = PromptBuilder.review(review)
    assert_includes prompt, "jest w diffie tego PR-a"
    assert_includes prompt, "plik.rb:12-20"
  end

  test "bez komentarzy inline prompt nie stawia wymagań co do linii" do
    review = reviews(:pr_review)
    review.update!(scope: { "areas" => %w[functionality], "inline_comments" => false })
    assert_not_includes PromptBuilder.review(review), "jest w diffie tego PR-a"
  end

  def with_repo(docs:)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, docs)) if docs
      review = reviews(:pr_review)
      relocate_repo!(review.project, dir)
      yield review
    end
  end

  test "nieudane runy nie liczą się jako konto, na którym coś powstało" do
    review = reviews(:pr_review)
    review.update!(claude_config: "/Users/dev/.claude-b")
    review.claude_runs.create!(kind: "review", claude_config: "/Users/dev/.claude", status: "failed")
    assert_not_includes PromptBuilder.review(review), "Kontekst poprzedniego review"
  end

  test "should point describe and review prompts at the branch diff for a self review" do
    review = Review.create!(project: projects(:webapp), branch: "sw-selfreview",
                            scope: { "areas" => %w[functionality] })

    [ PromptBuilder.describe(review), PromptBuilder.review(review) ].each do |prompt|
      assert_includes prompt, "`sw-selfreview`"
      assert_includes prompt, "origin/master"
      assert_not_includes prompt, "gh pr view"
      assert_not_includes prompt, "zadani" + "u: "
    end
  end

  test "should review the branch diff against the task when a branch comes with a task" do
    review = Review.create!(project: projects(:webapp), branch: "sw-fix", task_url: "https://tasks.example.com/9",
                            scope: { "self" => true })

    [ PromptBuilder.describe(review), PromptBuilder.review(review) ].each do |prompt|
      assert_includes prompt, "`sw-fix`"
      assert_includes prompt, "origin/master"
      assert_includes prompt, "https://tasks.example.com/9"
    end
    assert_includes PromptBuilder.review(review), "bądź surowy"
  end

  test "should mark a self review of an own PR as the author's round" do
    review = reviews(:pr_review)
    review.update!(scope: { "self" => true })

    prompt = PromptBuilder.review(review)
    assert_includes prompt, review.pr_url
    assert_includes prompt, "bądź surowy"
  end

  test "should build a fix prompt from findings and unmet task criteria" do
    review = reviews(:pr_review)
    review.update!(branch: "sl-fix-vat", worktree_path: "/wt/webapp-sl-fix-vat", task_url: "https://tasks.example.com/9",
                   scope: { "self" => true }, task_fit_status: "ready",
                   task_criteria: { "criteria" => [ { "id" => "ac1", "text" => "Faktura liczy VAT od netto" },
                                                    { "id" => "ac2", "text" => "PDF pokazuje stawkę" } ] },
                   task_fit: { "verdict" => "misses",
                               "criteria" => [ { "id" => "ac1", "status" => "unmet", "note" => "liczy od brutto" },
                                               { "id" => "ac2", "status" => "met" } ] })
    review.findings.create!(priority: "critical", title: "nil w kalkulacji", body: "pada dla pustej pozycji",
                            file_location: "app/models/invoice.rb:42")
    review.findings.create!(priority: "minor", title: "obalona uwaga", body: "x", verdict: "refuted")

    prompt = PromptBuilder.self_fix(review)

    assert_includes prompt, "`sl-fix-vat`"
    assert_includes prompt, "/wt/webapp-sl-fix-vat"
    assert_includes prompt, "https://tasks.example.com/9"
    assert_includes prompt, "nil w kalkulacji"
    assert_includes prompt, "app/models/invoice.rb:42"
    assert_includes prompt, "pada dla pustej pozycji"
    assert_includes prompt, "Faktura liczy VAT od netto"
    assert_includes prompt, "liczy od brutto"
    assert_not_includes prompt, "PDF pokazuje stawkę"
    assert_not_includes prompt, "obalona uwaga"
  end

  test "should warn the fixing agent when the task fit was not checked" do
    review = Review.create!(project: projects(:webapp), branch: "sw-fix", task_url: "https://tasks.example.com/9",
                            scope: { "self" => true })

    assert_includes PromptBuilder.self_fix(review), "Zgodności z zadaniem nie sprawdzono"
    review.update!(task_url: nil)
    assert_not_includes PromptBuilder.self_fix(review), "Zgodności z zadaniem nie sprawdzono"
  end

  test "should build an adversarial verify findings prompt with the finding ids" do
    review = reviews(:pr_review)
    review.update!(branch: "sl-fix-vat")
    finding = review.findings.create!(priority: "critical", title: "nil w kalkulacji", body: "scenariusz z nil")

    prompt = PromptBuilder.verify_findings(review)

    assert_includes prompt, "OBALIĆ"
    assert_includes prompt, "id #{finding.id}"
    assert_includes prompt, "verdicts.json"
    assert_includes prompt, "`sl-fix-vat`"
  end

  # --- rozmowa z PR-a w prompcie ---

  def discussion(review_comments:, issue_comments: [])
    snapshot = PrSnapshot.new("fetched_at" => "2026-09-01T10:00:00Z", "files" => [],
                              "review_comments" => review_comments, "issue_comments" => issue_comments,
                              "author" => "autorka", "viewer" => "reviewerka")
    PrDiscussion.new(snapshot)
  end

  def pin(finding, id:)
    { "id" => id, "path" => "app/models/invoice.rb", "line" => 12, "position" => 3,
      "subject_type" => "line", "user" => "reviewerka", "created_at" => "2026-08-29T10:00:00Z",
      "body" => "#{InlineComments.header_for(finding)}\n\n#{finding.body}" }
  end

  def reply(to:, body: "Zostawiam świadomie — dług z mastera.")
    { "id" => to + 1, "in_reply_to_id" => to, "user" => "autorka",
      "created_at" => "2026-08-30T10:00:00Z", "body" => body }
  end

  test "review z rozmową z PR-a cytuje autora i zakazuje powtarzania wyjaśnionej uwagi" do
    prompt = PromptBuilder.review(reviews(:pr_review),
                                  discussion: discussion(review_comments: [ pin(finding_for_pin, id: 1), reply(to: 1) ]))

    assert_includes prompt, "Dyskusja na PR-ze"
    assert_includes prompt, "autor PR-a (autorka)"
    assert_includes prompt, "Zostawiam świadomie — dług z mastera."
    assert_includes prompt, "Nigdy nie pisz, że autor się nie odniósł"
  end

  test "review bez rozmowy nie niesie pustej sekcji o niej" do
    assert_not_includes PromptBuilder.review(reviews(:pr_review)), "Dyskusja na PR-ze"
  end

  # Sama moja pinezka nie jest rozmową — jej treść sesja ma w liście znalezisk.
  test "pinezka bez odpowiedzi nie otwiera sekcji dyskusji" do
    prompt = PromptBuilder.review(reviews(:pr_review),
                                  discussion: discussion(review_comments: [ pin(finding_for_pin, id: 1) ]))

    assert_not_includes prompt, "Dyskusja na PR-ze"
  end

  # Weryfikacja poprawek orzeka per znalezisko, więc odpowiedź musi stać PRZY nim,
  # nie w zbiorczej sekcji na końcu.
  test "verify_fixes stawia odpowiedź autora przy znalezisku i zna status answered" do
    review = reviews(:pr_review)
    review.update!(decision_head_sha: "aaa1111", branch: "sl-fix")
    finding = review.findings.create!(priority: "critical", title: "Nil w kalkulacji VAT", body: "Problem: nil")
    talk = discussion(review_comments: [ pin(finding, id: 1), reply(to: 1) ])

    prompt = PromptBuilder.verify_fixes(review, discussion: talk)
    body, = prompt.split("## Czego oczekuję")

    assert_includes body, "Odpowiedzi na PR-ze pod tą uwagą"
    assert_includes body, "Zostawiam świadomie — dług z mastera."
    assert_includes prompt, "`answered`"
  end

  # Kilka osób ogląda PR-a: autor bywa, że wyjaśnia rzecz sam z siebie, zanim usiądę
  # do review. Taki komentarz nie ma odpowiedzi, a musi trafić do promptu.
  test "komentarz autora bez odpowiedzi też trafia do sekcji dyskusji" do
    solo = { "id" => 9, "path" => "app/models/invoice.rb", "line" => 12, "position" => 3,
             "subject_type" => "line", "user" => "autorka", "created_at" => "2026-08-28T10:00:00Z",
             "body" => "Wiem, że wygląda dziwnie — to świadome, guard leci w innym PR-ze." }
    prompt = PromptBuilder.review(reviews(:pr_review), discussion: discussion(review_comments: [ solo ]))

    assert_includes prompt, "guard leci w innym PR-ze"
    assert_includes prompt, "Liczy się KAŻDY głos"
    assert_includes prompt, "Nigdy nie pisz, że autor się nie odniósł"
  end

  # Odpowiedź bywa nie pod moją pinezką, tylko pod uwagą drugiego reviewera.
  test "verify_fixes pokazuje też wątki spoza moich pinezek" do
    review = reviews(:pr_review)
    review.update!(decision_head_sha: "aaa1111", branch: "sl-fix")
    finding = review.findings.create!(priority: "critical", title: "Nil w kalkulacji VAT", body: "Problem: nil")
    obcy = { "id" => 9, "path" => "app/models/order.rb", "line" => 5, "position" => 2,
             "subject_type" => "line", "user" => "autorka", "created_at" => "2026-08-28T10:00:00Z",
             "body" => "To samo tłumaczyłem drugiemu reviewerowi wyżej." }
    talk = discussion(review_comments: [ pin(finding, id: 1), reply(to: 1), obcy ])

    prompt = PromptBuilder.verify_fixes(review, discussion: talk)

    assert_includes prompt, "Pozostała dyskusja na PR-ze"
    assert_includes prompt, "To samo tłumaczyłem drugiemu reviewerowi wyżej."
    assert_includes prompt, "app/models/order.rb:5"
  end

  def finding_for_pin
    Finding.new(priority: "critical", title: "Nil w kalkulacji VAT", body: "Problem: nil",
                file_location: "app/models/invoice.rb:12")
  end

  test "task_fit: świeża sesja dostaje AC z id, regułę sprawdzalności i kontrakt task_fit.json" do
    review = reviews(:pr_review)
    review.update!(branch: "sl-2fa", task_description: "**Cel** — SMS ma dochodzić.",
                   task_criteria: { "criteria" => [ { "id" => "ac1", "text" => "Kod dochodzi do klienta" } ],
                                    "traps" => [ { "id" => "t1", "text" => "Czy autor odczytał log" } ],
                                    "process" => [ { "id" => "p1", "text" => "Link do Figmy", "status" => "missing", "note" => "brak w zadaniu" } ] })
    prompt = PromptBuilder.task_fit(review)
    assert_includes prompt, "Nie oceniasz jakości kodu"
    assert_includes prompt, "**Cel** — SMS ma dochodzić."
    assert_includes prompt, "id ac1"
    assert_includes prompt, "Kod dochodzi do klienta"
    assert_includes prompt, "id t1"
    assert_includes prompt, "id p1"
    assert_includes prompt, "unverifiable"
    assert_includes prompt, "needed_evidence"
    assert_includes prompt, "evidence_found"
    assert_includes prompt, "nie jest dowodem"
    assert_includes prompt, review.artifacts_dir.join("task_fit.json").to_s
    assert_includes prompt, "## Jak pisać"
    assert_not_includes prompt, "## Dyskusja na PR-ze"
  end

  test "task_fit niesie dyskusję z PR-a, gdy jest" do
    review = reviews(:pr_review)
    review.update!(branch: "sl-2fa", task_criteria: { "criteria" => [ { "id" => "ac1", "text" => "x" } ] })
    snapshot = PrSnapshot.new("fetched_at" => Time.current.iso8601, "files" => [], "review_comments" => [],
                              "issue_comments" => [ { "id" => 1, "user" => "tomek", "body" => "To nie naprawia zgłoszenia", "created_at" => "2026-09-08T10:00:00Z" } ],
                              "author" => "autorka", "viewer" => "ja")
    prompt = PromptBuilder.task_fit(review, discussion: PrDiscussion.new(snapshot))
    assert_includes prompt, "## Dyskusja na PR-ze"
    assert_includes prompt, "To nie naprawia zgłoszenia"
  end

  # ---- Zgodność z zadaniem w promptach review i followup

  test "review z opisem zadania każe rozliczyć AC z nazwy, pułapki i sprawdzalność z kodu" do
    review = reviews(:pr_review)
    review.update!(task_description: "**Cel** — x.\n\n**Niejasności / pułapki**\n- **log** — sprawdź, czy autor odczytał log")
    prompt = PromptBuilder.review(review)
    assert_includes prompt, "**Zgodność z zadaniem**"
    assert_includes prompt, "niesprawdzalne z kodu"
    assert_includes prompt, "„4 z 5”"
    assert_includes prompt, "Niejasności / pułapki"
    assert_includes prompt, "Do ręcznego sprawdzenia:"
    assert_includes prompt, "Nie rozwiązuje zadania:"
  end

  test "review bez opisu zadania nie każe pisać linii o zgodności" do
    assert_not_includes PromptBuilder.review(reviews(:pr_review)), "**Zgodność z zadaniem**"
  end

  test "followup każe wrócić do pytania, czy PR rozwiązuje zgłoszenie" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", worktree_path: Dir.tmpdir)
    prompt = PromptBuilder.followup(review, "sprawdź", resumed: true)
    assert_includes prompt, "czy PR rozwiązuje zgłoszenie"
    assert_includes prompt, "cudze review"
  end

  # Tura zakończona z zadaniem w tle to wynik, którego dashboard nigdy nie odbierze:
  # runner ubija sesję chwilę po `result`.
  test "followup zakazuje kończyć turę, gdy działają zadania w tle" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", worktree_path: Dir.tmpdir)
    prompt = PromptBuilder.followup(review, "sprawdź", resumed: true)
    assert_includes prompt, "Nie kończ odpowiedzi, dopóki działa cokolwiek w tle"
  end

  test "dyskusja z PR-a niesie cudze review z werdyktem" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", worktree_path: Dir.tmpdir)
    snapshot = PrSnapshot.new("fetched_at" => Time.current.iso8601, "files" => [], "review_comments" => [], "issue_comments" => [],
                              "reviews" => [ { "id" => 5, "user" => "tomek", "state" => "CHANGES_REQUESTED", "submitted_at" => "2026-09-08T10:36:00Z",
                                               "body" => "Log pokazuje count: 1, QUEUE. PR nie dotyka przyczyny." },
                                             { "id" => 6, "user" => "ja", "state" => "APPROVED", "submitted_at" => "2026-09-03T11:51:00Z", "body" => "LGTM" } ],
                              "author" => "autorka", "viewer" => "ja")
    prompt = PromptBuilder.review(review, discussion: PrDiscussion.new(snapshot))
    assert_includes prompt, "### Cudze review pod PR-em"
    assert_includes prompt, "tomek"
    assert_includes prompt, "CHANGES_REQUESTED"
    assert_includes prompt, "PR nie dotyka przyczyny"
    assert_not_includes prompt, "LGTM"
  end

  # ---- Uzgodnienie wyniku review z weryfikacją i zgodnością

  def reconcile_review
    review = reviews(:pr_review)
    review.update!(summary: "**Krótko:** approve, jedna poprawka.",
                   task_criteria: { "criteria" => [ { "id" => "ac1", "text" => "Kod dochodzi do klienta" } ],
                                    "traps" => [ { "id" => "t1", "text" => "Czy autor odczytał log" } ] },
                   task_fit_status: "ready",
                   task_fit: { "verdict" => "misses", "symptom" => "SMS nie dochodzi", "assumed_cause" => "zła kolejka",
                               "evidence" => "brak logu", "evidence_found" => false,
                               "criteria" => [ { "id" => "ac1", "status" => "unmet", "note" => "kod omija kolejkę",
                                                 "needed_evidence" => "log z bramki SMS" } ],
                               "traps" => [ { "id" => "t1", "status" => "open", "note" => "brak odniesienia" } ] })
    review
  end

  test "prompt uzgodnienia niesie notatki weryfikatora, punkty zgodności i ścieżkę wyniku" do
    review = reconcile_review
    refuted = review.findings.create!(priority: "important", title: "Nil w kalkulacji", body: "Problem: nil",
                                      file_location: "app/a.rb:3", verdict: "refuted", verdict_note: "guard w app/a.rb:3")
    disputed = review.findings.create!(priority: "minor", title: "Nazwa metody", body: "Problem: nazwa",
                                       verdict: "disputed", verdict_note: "kwestia gustu")
    confirmed = review.findings.create!(priority: "critical", title: "Brak walidacji", body: "Problem: walidacja",
                                        verdict: "confirmed", verdict_note: "potwierdzam")

    prompt = PromptBuilder.reconcile(review, resumed: true)

    assert_includes prompt, "id #{refuted.id} "
    assert_includes prompt, "guard w app/a.rb:3"
    assert_includes prompt, "id #{disputed.id} "
    assert_includes prompt, "kwestia gustu"
    assert_not_includes prompt, "id #{confirmed.id} "
    assert_not_includes prompt, "potwierdzam"
    assert_includes prompt, "id ac1"
    assert_includes prompt, "Kod dochodzi do klienta"
    assert_includes prompt, "kod omija kolejkę"
    assert_includes prompt, "log z bramki SMS"
    assert_includes prompt, "SMS nie dochodzi"
    assert_includes prompt, "**Krótko:** approve, jedna poprawka."
    assert_includes prompt, "task_fit_changes"
    assert_includes prompt, review.artifacts_dir.join("reconcile.json").to_s
    assert_includes prompt, "masz pełny kontekst poprzedniej sesji"
    assert_includes prompt, "Nie kończ odpowiedzi, dopóki działa cokolwiek w tle"
    assert_includes prompt, File.read(PromptBuilder::STYLE_PATH).lines.first.strip
    assert_not_includes prompt, "Kontekst poprzedniego review"
  end

  # Sesja ocenia oryginalny wynik zgodności, nie nakładkę z poprzedniego uzgodnienia -
  # inaczej drugie uzgodnienie potwierdzałoby własne zmiany zamiast je sprawdzić.
  test "prompt uzgodnienia pokazuje oryginalne statusy zgodności, nie nakładkę" do
    review = reconcile_review
    review.update!(task_fit_reconciliation: { "changes" => { "ac1" => { "from" => "unmet", "to" => "met", "note" => "NAKŁADKA" } } })

    prompt = PromptBuilder.reconcile(review, resumed: true)

    assert_includes prompt, "kod omija kolejkę"
    assert_not_includes prompt, "NAKŁADKA"
  end

  test "świeża sesja uzgodnienia dostaje kontekst i polecenie przeczytania result.json" do
    review = reconcile_review
    FileUtils.mkdir_p(review.artifacts_dir)
    File.write(review.artifacts_dir.join("result.json"), "{}")

    prompt = PromptBuilder.reconcile(review, resumed: false)

    assert_includes prompt, review.artifacts_dir.join("result.json").to_s
    assert_includes prompt, "Kontekst poprzedniego review"
    assert_not_includes prompt, "masz pełny kontekst poprzedniej sesji"
  ensure
    FileUtils.rm_rf(review.artifacts_dir) if review
  end

  test "uzgodnienie bez wyniku zgodności nie niesie sekcji o punktach" do
    review = reviews(:pr_review)
    review.findings.create!(priority: "minor", title: "x", body: "y", verdict: "refuted", verdict_note: "z")

    prompt = PromptBuilder.reconcile(review, resumed: true)

    assert_not_includes prompt, "## Zgodność z zadaniem"
  end

  # TaskFitImporter.verdict_for daje „misses” nie tylko za niespełnione AC - także za otwartą
  # pułapkę, brak w procesie i brak dowodu na przyczynę. Krótko musi iść tą samą regułą.
  test "prompt uzgodnienia niesie pełną regułę Krótko zgodną z werdyktem zgodności" do
    prompt = PromptBuilder.reconcile(reconcile_review, resumed: true)
    rule = prompt[/^- `\*\*Krótko:\*\*`.*?(?=^- [^ ])/m]
    assert rule, "brak reguły Krótko"
    [ "AC `unmet`", "pułapka `open`", "wymóg procesu `missing`", "`evidence_found`", "„Nie rozwiązuje zadania: …”",
      "`unverifiable`", "„Do ręcznego sprawdzenia: …”", "approve" ].each { |fragment| assert_includes rule, fragment }
  end

  # Drugie uzgodnienie nie może rozstrzygać w ciemno: musi widzieć, co postanowiło pierwsze.
  test "prompt uzgodnienia pokazuje poprzednie rozstrzygnięcie znaleziska" do
    review = reconcile_review
    review.findings.create!(priority: "minor", title: "Nil", body: "x", verdict: "refuted", verdict_note: "guard",
                            resolution: "dropped", resolution_note: "guard w a.rb:3 to łapie")
    prompt = PromptBuilder.reconcile(review, resumed: true)
    assert_includes prompt, "**Poprzednie rozstrzygnięcie:** `dropped` — guard w a.rb:3 to łapie"
    assert_includes prompt, "musi znów pojawić się w `summary`"
  end

  # note zmiany punktu ląduje w decyzji przy punkcie (DecisionDraft#note_suffix).
  test "prompt uzgodnienia każe pisać note zmiany punktu jako dowód dla autora, bez sporu" do
    prompt = PromptBuilder.reconcile(reconcile_review, resumed: true)
    assert_includes prompt, "`note` zmiany punktu trafia do autora PR-a"
  end

  # Przykład do skopiowania przeszedłby przez importer jako zmiana ac1 na „met” z notatką „dowód: …”.
  test "przykład JSON w prompcie uzgodnienia nie niesie gotowych zmian do skopiowania" do
    prompt = PromptBuilder.reconcile(reconcile_review, resumed: true)
    example = JSON.parse(prompt[/```json\n(.*?)```/m, 1])
    assert_equal({ "findings" => [], "task_fit_changes" => [] }, example.except("summary"))
  end

  # Followup przepisuje cały result.json, a ten dalej trzyma znaleziska sprzed uzgodnienia.
  test "followup nie przywraca znalezisk usuniętych po uzgodnieniu" do
    review = reviews(:pr_review)
    review.update!(summary: "S")
    review.findings.create!(priority: "minor", title: "Usunięta uwaga", body: "x", resolution: "dropped")
    review.findings.create!(priority: "minor", title: "Zostawiona uwaga", body: "x", resolution: "kept")

    fresh = PromptBuilder.followup(review, "sprawdź", resumed: false)
    context = fresh[/## Kontekst poprzedniego review.*?(?=Reviewer \(człowiek\))/m]
    assert_not_includes context, "Usunięta uwaga"
    assert_includes context, "Zostawiona uwaga"

    prompt = PromptBuilder.followup(review, "sprawdź", resumed: true)
    assert_includes prompt, "usunięte po uzgodnieniu"
    assert_includes prompt, "  - Usunięta uwaga"
    assert_not_includes prompt, "  - Zostawiona uwaga"
  end

  test "verify_fixes pomija usunięte po uzgodnieniu znaleziska, zostawione zostają" do
    review = reviews(:pr_review)
    review.update!(decision_head_sha: "aaa1111", branch: "sl-fix")
    review.findings.create!(priority: "critical", title: "Usunięta uwaga", body: "x", resolution: "dropped")
    review.findings.create!(priority: "minor", title: "Zostawiona uwaga", body: "x", resolution: "kept")

    _, list = PromptBuilder.verify_fixes(review).split("## Znaleziska do sprawdzenia")
    assert_not_includes list, "Usunięta uwaga"
    assert_includes list, "Zostawiona uwaga"
  end

  test "self_fix pomija usunięte, a obaloną uwagę zostawioną po uzgodnieniu zachowuje" do
    review = reviews(:pr_review)
    review.findings.create!(priority: "critical", title: "Usunięta uwaga", body: "x", resolution: "dropped")
    review.findings.create!(priority: "minor", title: "Obalona i zostawiona", body: "x", verdict: "refuted", resolution: "kept")
    review.findings.create!(priority: "minor", title: "Obalona i obniżona", body: "x", verdict: "refuted", resolution: "downgraded")
    review.findings.create!(priority: "minor", title: "Obalona bez uzgodnienia", body: "x", verdict: "refuted")

    prompt = PromptBuilder.self_fix(review)
    assert_not_includes prompt, "Usunięta uwaga"
    assert_not_includes prompt, "Obalona bez uzgodnienia"
    assert_includes prompt, "Obalona i zostawiona"
    assert_includes prompt, "Obalona i obniżona"
  end
end
