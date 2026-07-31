require "test_helper"

class ReviewTest < ActiveSupport::TestCase
  test "effective_task_comment_instructions: zamrożona na review wygrywa z projektem" do
    review = reviews(:task_only)
    review.project.update!(task_comment_instructions: "Z PROJEKTU")
    assert_equal "Z PROJEKTU", review.effective_task_comment_instructions

    review.update!(task_comment_instructions: "ZAMROŻONA")
    assert_equal "ZAMROŻONA", review.effective_task_comment_instructions
  end

  test "wymaga pr_url, task_url albo brancha" do
    review = Review.new(project: projects(:webapp))
    assert_not review.valid?
    assert_equal [ "Podaj link do PR, link do zadania albo branch (samoreview)" ], review.errors[:base]
  end

  # Ta sama wartość jest już utwardzona po stronie Project (default_claude_config) —
  # zostawienie review otwartym na dowolną ścieżkę byłoby niespójne, a switch_config
  # sam w sobie nie chroni przed formularzem create/update (permit :claude_config).
  test "odrzuca claude_config spoza listy dostępnych configów, przyjmuje puste" do
    review = reviews(:pr_review)
    review.claude_config = "/etc/passwd"
    assert_not review.valid?

    review.claude_config = "/Users/dev/.claude-b"
    assert review.valid?, review.errors.full_messages.to_sentence

    review.claude_config = ""
    assert review.valid?, review.errors.full_messages.to_sentence
  end

  test "task_description_status przyjmuje tylko znane wartości" do
    review = reviews(:pr_review)
    Review::TASK_DESCRIPTION_STATUSES.each do |s|
      review.task_description_status = s
      assert review.valid?, "#{s} powinien być legalny"
    end
    review.task_description_status = "bzdura"
    assert_not review.valid?
  end

  test "waiting_review jest legalnym statusem" do
    review = reviews(:pr_review)
    review.status = "waiting_review"
    assert review.valid?
  end

  # Strumień wiersza listy musi być per projekt — inaczej wiersz z projektu A
  # wypływa na otwartą listę projektu B, gdzie nawet nie istnieje. `args` trzeba
  # zapisywać jawnie: stub, który je odrzuca (jak poprzednio), przepuściłby
  # cofnięcie broadcastu na globalny strumień "reviews" bez żadnego czerwonego testu.
  test "zmiana statusu rozgłasza wiersz we własnym strumieniu projektu" do
    review = reviews(:pr_review)
    targets = []
    streams = []
    review.stub :broadcast_replace_to, ->(*args, **kw) { streams << args; targets << kw[:target] } do
      review.update!(status: "reviewed")
    end
    assert_includes targets, "review_row_#{review.id}"
    assert_includes streams, [ review.project, :reviews ]
  end

  test "zmiana bez statusu nie rozgłasza wiersza" do
    review = reviews(:pr_review)
    targets = []
    streams = []
    review.stub :broadcast_replace_to, ->(*args, **kw) { streams << args; targets << kw[:target] } do
      review.update!(summary: "nowe podsumowanie")
    end
    assert_not_includes targets, "review_row_#{review.id}"
  end

  # Nowa walidacja na Project blokuje zapis złego wzorca przez formularz, ale
  # nie chroni danych, które trafiły do bazy wcześniej (albo update_column). Ta sama
  # literówka w %{branch} rzuca KeyError, nie WorktreeManager::Error — bez rescue
  # StandardError destroy wywaliłby się PO tym, jak remove_artifacts już skasował
  # katalog, zostawiając review zawieszone w dashboardzie z bezpowrotnie utraconymi
  # artefaktami.
  test "destroy usuwa review mimo zepsutego wzorca komendy worktree (literówka w %{branch})" do
    review = reviews(:pr_review)
    review.project.update_column(:worktree_delete_command, "bin/wt %{brnach}")
    review.update!(branch: "sl-fix-vat", worktree_path: "/tmp/wt-sl-fix-vat-#{review.id}")

    assert_nothing_raised { review.destroy! }

    assert_not Review.exists?(review.id)
    assert_match(/brnach/, review.worktree_removal_error)
  end

  # Sedno: „ścieżka w bazie" i „katalog na dysku" to dwie różne rzeczy — worktree ginie
  # też poza dashboardem, a wtedy w bazie zostaje ścieżka donikąd.
  test "worktree_exists? odróżnia istniejący katalog od ścieżki donikąd" do
    review = reviews(:pr_review)

    review.update!(worktree_path: Dir.tmpdir)
    assert review.worktree_exists?

    review.update!(worktree_path: File.join(Dir.tmpdir, "nie-ma-mnie-#{review.id}"))
    assert_not review.worktree_exists?
  end

  test "worktree_exists? jest fałszem, gdy review pracuje wprost w repo projektu" do
    review = reviews(:pr_review)
    # repo_path z fixture musi istnieć, żeby test mierzył warunek, a nie brak katalogu.
    relocate_repo!(review.project, Dir.tmpdir)
    review.update!(worktree_path: Dir.tmpdir)

    assert_nil review.own_worktree_path
    assert_not review.worktree_exists?
  end

  test "artifacts_dir wskazuje na storage/reviews/<id>" do
    review = reviews(:pr_review)
    assert_equal Rails.root.join("storage", "reviews", review.id.to_s), review.artifacts_dir
  end

  test "destroy kasuje katalog artefaktów" do
    review = reviews(:pr_review)
    FileUtils.mkdir_p(review.artifacts_dir)
    File.write(review.artifacts_dir.join("result.json"), "{}")
    review.destroy!
    assert_not File.exist?(review.artifacts_dir)
  end

  test "błąd broadcastu nie wywraca zapisu (fail! przechodzi mimo wyjątku renderu)" do
    review = reviews(:pr_review)
    review.stub :broadcast_replace_to, ->(*_a, **_kw) { raise "render boom" } do
      review.fail!("coś padło")
    end
    assert_equal "failed", review.reload.status
  end

  test "destroy zabija żywe procesy claude po pid" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: "/x", status: "running", pid: 55_555)
    review.claude_runs.create!(kind: "describe", claude_config: "/x", status: "succeeded", pid: 44_444)
    killed = []
    CommandRunner.stub :kill_group, ->(pid, **) { killed << pid } do
      review.destroy!
    end
    assert_equal [ 55_555 ], killed
  end

  # Realny scenariusz: worker padł, zostawił nowszy run-duch (aborted, bez last_message),
  # a starsza sesja pracowała dalej — panel pokazywał wtedy „Startuję…" zamiast postępu.
  test "running_claude_run wskazuje pracującą sesję, nie nowszy przerwany run" do
    review = reviews(:pr_review)
    working = review.claude_runs.create!(kind: "review", claude_config: "/x", status: "running", last_message: "Analizuję diff")
    review.claude_runs.create!(kind: "review", claude_config: "/x", status: "aborted")
    assert_equal working, review.running_claude_run
  end

  test "running_claude_run milczy, gdy żadna sesja nie pracuje" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: "/x", status: "failed")
    assert_nil review.running_claude_run
  end

  test "github_actions_available? tylko gdy jest pr_url" do
    assert reviews(:pr_review).github_actions_available?
    assert_not reviews(:task_only).github_actions_available?
  end

  test "branch z niedozwolonymi znakami jest odrzucany" do
    review = reviews(:pr_review)
    assert review.update(branch: "sl-fix/vat_2.0")
    assert_not review.update(branch: "x; rm -rf ~")
    assert_not review.update(branch: "a b")
  end

  # Stare review nie mają klucza w scope, a nie chcemy, żeby cicho straciły pinezki.
  test "komentarze inline domyślnie włączone, wyłącza je dopiero jawne false" do
    review = reviews(:pr_review)
    assert review.inline_comments?
    review.update!(scope: { "areas" => %w[functionality] })
    assert review.inline_comments?
    review.update!(scope: { "inline_comments" => false })
    assert_not review.inline_comments?
  end

  test "projekt z wyczyszczoną ścieżką dokumentacji nie ma jej do przekazania" do
    review = reviews(:pr_review)
    review.project.update!(docs_path: "")
    assert_nil review.available_docs_path
  end

  test "scope przechowuje obszary i notatki" do
    review = reviews(:pr_review)
    review.update!(scope: { "areas" => %w[functionality qa_playwright], "notes" => "sprawdź VAT" })
    assert_equal(
      { "areas" => %w[functionality qa_playwright], "notes" => "sprawdź VAT" },
      review.reload.scope
    )
  end

  test "odrzuca PR z repozytorium innego projektu" do
    review = Review.new(project: projects(:webapp), pr_url: "https://github.com/acme/inne-repo/pull/7")
    assert_not review.valid?
    assert_match(/acme\/inne-repo/, review.errors[:pr_url].to_sentence)
    assert_match(/acme\/webapp/, review.errors[:pr_url].to_sentence)
  end

  test "przyjmuje PR z repozytorium projektu niezależnie od wielkości liter" do
    review = Review.new(project: projects(:webapp), pr_url: "https://github.com/Acme/Webapp/pull/7")
    assert review.valid?, review.errors.full_messages.to_sentence
  end

  test "odrzuca link, który nie jest PR-em na GitHubie, gdy projekt ma repozytorium" do
    review = Review.new(project: projects(:webapp), pr_url: "https://example.com/pull/7")
    assert_not review.valid?
  end

  test "nie sprawdza PR-a, gdy projekt nie ma adresu repozytorium" do
    project = projects(:webapp)
    project.update!(repo_url: nil)
    review = Review.new(project: project, pr_url: "https://github.com/kto/inne/pull/7")
    assert review.valid?, review.errors.full_messages.to_sentence
  end

  test "drugi review tego samego PR-a jest odrzucany, a duplicate_review wskazuje istniejący" do
    existing = reviews(:pr_review)
    review = Review.new(project: projects(:webapp), pr_url: "https://github.com/Acme/Webapp/pull/1234/files")
    assert_not review.valid?
    assert_equal existing, review.duplicate_review
    assert_match(/ma już review/, review.errors[:pr_url].to_sentence)
  end

  test "inny numer PR-a w tym samym repo nie jest duplikatem" do
    review = Review.new(project: projects(:webapp), pr_url: "https://github.com/acme/webapp/pull/9999")
    assert review.valid?, review.errors.full_messages.to_sentence
  end

  test "duplikat PR-a nie blokuje aktualizacji istniejącego review" do
    review = reviews(:pr_review)
    review.update!(status: "ready")
    assert_equal "ready", review.reload.status
  end

  test "nie pozwala założyć review w zarchiwizowanym projekcie" do
    project = projects(:webapp)
    project.update!(archived_at: Time.current)
    review = Review.new(project: project, pr_url: "https://github.com/acme/webapp/pull/7")
    assert_not review.valid?
    assert_match(/zarchiwizowany/, review.errors[:base].to_sentence)
  end

  test "archiwizacja projektu nie blokuje aktualizacji istniejących review" do
    review = reviews(:pr_review)
    review.project.update!(archived_at: Time.current)
    review.update!(status: "reviewing")
    assert_equal "reviewing", review.reload.status
  end

  # Realny wyzwalacz: edycja repo_url projektu (formularz z zadania 4) po tym, jak
  # review już istnieje. Bez on: :create każdy update! (w tym fail! z jobów) rzuciłby
  # RecordInvalid — review zawieszony bez komunikatu, a OrphanedRunsCleanup wywaliłby
  # się w pętli find_each, przerywając sprzątanie także pozostałym review.
  test "zmiana repo_url projektu na niepasujące nie blokuje aktualizacji istniejących review" do
    review = reviews(:pr_review)
    review.project.update!(repo_url: "https://github.com/acme/inne-repo")
    review.update!(status: "reviewing")
    assert_equal "reviewing", review.reload.status
  end

  test "zmiana repo_url projektu na niepasujące nie blokuje fail! na istniejących review" do
    review = reviews(:pr_review)
    review.project.update!(repo_url: "https://github.com/acme/inne-repo")
    review.fail!("coś padło")
    assert_equal "failed", review.reload.status
  end

  # Kontekst to własność sesji, do której wracają followupy — nie sumy po review.
  test "context_usage liczy procent z najnowszej wznawialnej sesji" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: "/c", context_tokens: 120_000, context_window: 1_000_000)
    review.claude_runs.create!(kind: "followup", claude_config: "/c", context_tokens: 289_135, context_window: 1_000_000)
    usage = review.context_usage
    assert_equal({ tokens: 289_135, window: 1_000_000, percent: 29, measured: true },
                 { tokens: usage.tokens, window: usage.window, percent: usage.percent, measured: usage.measured? })
  end

  test "context_usage ignoruje sesję describe" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: "/c", context_tokens: 5000, context_window: 1_000_000)
    review.claude_runs.create!(kind: "describe", claude_config: "/c", context_tokens: 999_999, context_window: 1_000_000)
    assert_equal 5000, review.context_usage.tokens
  end

  test "context_usage bez żadnej wznawialnej sesji jest nil" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "describe", claude_config: "/c", context_tokens: 5000)
    assert_nil review.context_usage
  end

  # Po compakcie stary pomiar jest nieprawdą — schodzenie niżej po starszy run
  # pokazywałoby liczbę sprzed kompakcji jako aktualną.
  test "najnowsza sesja bez pomiaru daje odczyt niezmierzony, bez cofania się do starszej" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "followup", claude_config: "/c", context_tokens: 289_135, context_window: 1_000_000)
    review.claude_runs.create!(kind: "compact", claude_config: "/c")
    usage = review.context_usage
    assert_not usage.measured?
    assert_nil usage.percent
  end

  # Okno przychodzi dopiero w evencie `result` — w trakcie pierwszej sesji bierzemy
  # ostatnie znane, zamiast chować procent do końca przebiegu.
  test "brak okna w bieżącej sesji dobiera ostatnie znane" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: "/c", context_tokens: 10_000, context_window: 1_000_000)
    review.claude_runs.create!(kind: "followup", claude_config: "/c", context_tokens: 400_000)
    assert_equal({ window: 1_000_000, percent: 40 },
                 { window: review.context_usage.window, percent: review.context_usage.percent })
  end

  test "pomiar bez znanego okna nie zmyśla procentu" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: "/c", context_tokens: 10_000)
    usage = review.context_usage
    assert usage.measured?
    assert_nil usage.percent
  end

  test "compactable? wymaga sesji na bieżącym koncie" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed")
    assert_not review.compactable?, "bez żadnej sesji nie ma czego kompaktować"
  end

  test "compactable? jest fałszem, gdy sesja pracuje" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing")
    review.claude_runs.create!(kind: "review", claude_config: "/c", status: "running")
    assert_not review.compactable?
  end

  test "compactable? jest fałszem dla review skończonego" do
    review = reviews(:pr_review)
    review.update!(status: "merged")
    assert_not review.compactable?
  end

  # Bez tego followup po kompakcji wznowiłby sesję sprzed niej — czyli dokładnie tę,
  # którą user chciał zmniejszyć.
  test "resumable_session_run wybiera sesję compactu, gdy jest najnowsza" do
    config = Dir.mktmpdir
    review = reviews(:pr_review)
    %w[review compact].each do |kind|
      run = review.claude_runs.create!(kind: kind, claude_config: config, status: "succeeded",
                                       session_id: "sess-#{kind}")
      path = run.session_file(config)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, "{}")
    end
    assert_equal "sess-compact", review.resumable_session_run(config).session_id
  ensure
    FileUtils.remove_entry(config)
  end

  # Weryfikacja poprawek potrzebuje czterech rzeczy naraz; brak którejkolwiek znaczy,
  # że nie ma od czego liczyć diffu albo czego sprawdzać.
  test "should allow verifying fixes only after a decision on a PR with findings" do
    review = reviews(:pr_review)
    review.update!(status: "decided", decision: "comment", decision_head_sha: "aaa1111",
                   branch: "sl-fix-vat")
    assert_not review.fixes_verifiable?, "bez znalezisk nie ma czego sprawdzać"

    review.findings.create!(priority: "minor", title: "literówka", body: "x")
    assert review.reload.fixes_verifiable?

    review.update!(status: "reviewed")
    assert_not review.reload.fixes_verifiable?, "przed decyzją nie ma punktu odniesienia"

    review.update!(status: "waiting_review")
    assert review.reload.fixes_verifiable?, "po prośbie o ponowne review tym bardziej"

    review.update_columns(decision_head_sha: nil)
    assert_not review.reload.fixes_verifiable?
  end

  test "should summarise fix verdicts for the findings header" do
    review = reviews(:pr_review)
    review.findings.create!(priority: "critical", title: "a", body: "x", fix_status: "implemented")
    review.findings.create!(priority: "minor", title: "b", body: "y", fix_status: "implemented")
    review.findings.create!(priority: "minor", title: "c", body: "z")

    assert_equal({ "implemented" => 2 }, review.fix_summary)
  end

  test "should accept a branch-only review and flag it as self review" do
    review = Review.new(project: projects(:webapp), branch: "sw-moja-zmiana")

    assert review.valid?, review.errors.full_messages.to_sentence
    assert review.self_review?
    assert_equal "branch sw-moja-zmiana", review.task_link
  end

  test "should not treat reviews with a PR or a task as self reviews" do
    assert_not reviews(:pr_review).self_review?
    assert_not reviews(:task_only).self_review?
  end

  test "should exclude self reviews from the outward scope" do
    self_review = Review.create!(project: projects(:webapp), branch: "sw-samoreview")

    assert_not_includes Review.outward, self_review
    assert_includes Review.outward, reviews(:pr_review)
    assert_includes Review.outward, reviews(:task_only)
  end

  test "should allow verifying the findings only with a branch, findings and a settled review" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", branch: "sl-fix-vat")
    assert_not review.findings_verifiable?, "bez znalezisk nie ma czego weryfikować"

    review.findings.create!(priority: "critical", title: "nil", body: "x")
    assert review.reload.findings_verifiable?

    review.update!(status: "decided")
    assert review.findings_verifiable?, "po decyzji też — autor może podważać uwagi"

    review.update!(status: "reviewing")
    assert_not review.findings_verifiable?, "w trakcie review nie ma jeszcze pełnej listy"

    review.update!(status: "reviewed", branch: nil)
    assert_not review.findings_verifiable?, "bez brancha sesja nie ma czego czytać"
  end

  test "should block a second verification while one is pending" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", branch: "sl-fix-vat")
    review.findings.create!(priority: "critical", title: "nil", body: "x")
    run = review.claude_runs.create!(kind: "verify_findings", claude_config: "/Users/dev/.claude")

    assert_not review.findings_verifiable?

    run.update!(status: "succeeded")
    assert review.reload.findings_verifiable?, "po zakończonej weryfikacji można ponowić"
  end

  test "should tally the verdicts for the findings header" do
    review = reviews(:pr_review)
    review.findings.create!(priority: "critical", title: "a", body: "x", verdict: "refuted")
    review.findings.create!(priority: "minor", title: "b", body: "y", verdict: "refuted")
    review.findings.create!(priority: "minor", title: "c", body: "z")

    assert_equal({ "refuted" => 2 }, review.verdict_summary)
  end
end
