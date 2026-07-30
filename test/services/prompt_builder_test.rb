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
    assert_equal 5, templates.size
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

  test "describe_task z linkiem każe czytać zadanie i komentarze" do
    prompt = PromptBuilder.describe_task(reviews(:task_only))
    assert_includes prompt, "https://tasks.example.com/555"
    assert_includes prompt, "komentarz"
    assert_includes prompt, "TASK_URL:"
    assert_includes prompt, "**Acceptance Criteria**"
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
end
