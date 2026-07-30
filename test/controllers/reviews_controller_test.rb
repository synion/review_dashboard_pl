require "test_helper"

class ReviewsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup { @project = projects(:webapp) }

  test "index renderuje listę" do
    get project_reviews_path(@project)
    assert_response :success
    assert_select "table#reviews tbody tr", count: @project.reviews.count
  end

  test "lista pokazuje wyłącznie review swojego projektu" do
    other = projects(:dashboard).reviews.create!(pr_url: "https://github.com/example/dashboard/pull/3")

    get project_reviews_path(@project)
    assert_select "tr#review_row_#{other.id}", count: 0

    get project_reviews_path(projects(:dashboard))
    assert_select "tr#review_row_#{other.id}", count: 1
    assert_select "table#reviews tbody tr", count: 1
  end

  test "wejście na projekt nie kolejkuje sprawdzeń dla review innego projektu" do
    other = projects(:dashboard).reviews.create!(pr_url: "https://github.com/example/dashboard/pull/3",
                                                 status: "decided", github_checked_at: nil)
    assert_no_enqueued_jobs(only: CheckReviewRequestJob) do
      get project_reviews_path(@project)
    end
    assert_nil other.reload.github_checked_at
  end

  test "index sortuje po dacie malejąco domyślnie i filtruje po statusie" do
    reviews(:pr_review).update!(status: "reviewed")
    get project_reviews_path(@project, status: "reviewed")
    assert_select "table#reviews tbody tr", count: 1
  end

  # Sedno kolumny „Aktywność": stare review, do którego wróciłem dziś, ma wyglądać
  # inaczej niż stare review, którego nikt nie ruszał.
  test "lista pokazuje datę ostatniej aktywności, nie tylko utworzenia" do
    review = reviews(:pr_review)
    review.update_columns(created_at: 8.days.ago, updated_at: 8.days.ago)
    get project_reviews_path(@project)
    assert_equal I18n.l(review.reload.updated_at, format: :short),
                 css_select("tr#review_row_#{review.id} td.activity-cell").text

    review.update!(status: "reviewed")
    get project_reviews_path(@project)
    assert_match(/\Adziś \d\d:\d\d\z/, css_select("tr#review_row_#{review.id} td.activity-cell").text)
  end

  test "index sortuje po ostatniej aktywności" do
    stary = reviews(:pr_review)
    stary.update_columns(created_at: 1.hour.ago, updated_at: 8.days.ago)
    reviews(:task_only).update_columns(created_at: 8.days.ago, updated_at: 1.minute.ago)

    get project_reviews_path(@project, sort: "updated_at")
    assert_equal "review_row_#{reviews(:task_only).id}", css_select("table#reviews tbody tr").first["id"]

    get project_reviews_path(@project, sort: "updated_at", direction: "asc")
    assert_equal "review_row_#{stary.id}", css_select("table#reviews tbody tr").first["id"]
  end

  # Bez tego kliknięcie w „Aktywność" po przestawieniu „Daty" na rosnąco otwierało
  # listę od najstarszych — kierunek dziedziczył się z poprzedniej kolumny.
  test "nagłówek sortowania przełącza kierunek tylko na aktywnej kolumnie" do
    get project_reviews_path(@project, sort: "created_at", direction: "asc")
    assert_select "th a[href=?]", project_reviews_path(@project, sort: "created_at", direction: "desc")
    assert_select "th a[href=?]", project_reviews_path(@project, sort: "updated_at", direction: "desc")
  end

  # Trzy stany worktree na liście — ostrzeżenie o zniknięciu jest tu sednem, bo followup
  # w nieistniejącym katalogu pada dopiero po starcie sesji.
  test "lista pokazuje stan worktree" do
    review = reviews(:pr_review)

    review.update!(worktree_path: nil)
    get project_reviews_path(@project)
    assert_select "tr#review_row_#{review.id} td.worktree-cell span.wt-none"

    review.update!(worktree_path: Dir.tmpdir)
    get project_reviews_path(@project)
    assert_select "tr#review_row_#{review.id} td.worktree-cell span.wt-ok"

    review.update!(worktree_path: File.join(Dir.tmpdir, "nie-ma-mnie-#{review.id}"))
    get project_reviews_path(@project)
    assert_select "tr#review_row_#{review.id} td.worktree-cell span.wt-gone", text: /znikł/
  end

  test "panel review mówi, że worktree zniknął spoza dashboardu" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", branch: "sl-fix-vat",
                   worktree_path: File.join(Dir.tmpdir, "nie-ma-mnie-#{review.id}"))

    get review_path(review)
    assert_select "p.worktree-line.wt-gone", text: /katalogu już nie ma/
    # Bazy devowe przeżywają skasowany katalog — bez tego przycisku nie ma czym ich sprzątnąć.
    assert_select "form[action=?]", remove_worktree_review_path(review)
  end

  test "lista odróżnia review czekające w kolejce od pracującego" do
    reviews(:pr_review).update!(status: "reviewing")
    get project_reviews_path(@project)
    assert_select "tr", text: /Czeka w kolejce/
  end

  test "lista nie oznacza kolejką review z pracującą sesją" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing")
    review.claude_runs.create!(kind: "review", claude_config: "/x", status: "running")
    get project_reviews_path(@project)
    assert_select "tr", text: /Czeka w kolejce/, count: 0
  end

  test "lista pyta o pracujące sesje raz, nie raz na wiersz" do
    Review.update_all(status: "reviewing")
    assert_operator Review.count, :>=, 2, "test ma sens tylko przy kilku review"
    queries = 0
    counter = ->(*, payload) { queries += 1 if payload[:sql].include?("claude_runs") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get project_reviews_path(@project) }
    assert_equal 1, queries
  end

  test "index kolejkuje sprawdzenie re-requesta dla decided z przeterminowanym cache" do
    review = reviews(:pr_review)
    review.update!(status: "decided", github_checked_at: 2.hours.ago)
    assert_enqueued_with(job: CheckReviewRequestJob, args: [ review ]) do
      get project_reviews_path(@project)
    end
  end

  test "index kolejkuje sprawdzenie także gdy github_checked_at jest puste" do
    reviews(:pr_review).update!(status: "decided", github_checked_at: nil)
    assert_enqueued_with(job: CheckReviewRequestJob) { get project_reviews_path(@project) }
  end

  test "drugie wejście na listę nie dubluje sprawdzeń" do
    reviews(:pr_review).update!(status: "decided", github_checked_at: nil)
    get project_reviews_path(@project)
    assert_no_enqueued_jobs(only: CheckReviewRequestJob) { get project_reviews_path(@project) }
  end

  test "index nie kolejkuje dla świeżo sprawdzonych" do
    reviews(:pr_review).update!(status: "decided", github_checked_at: 10.minutes.ago)
    assert_no_enqueued_jobs(only: CheckReviewRequestJob) { get project_reviews_path(@project) }
  end

  test "index nie kolejkuje dla innych statusów ani review bez PR-a" do
    reviews(:pr_review).update!(status: "reviewed")
    reviews(:task_only).update!(status: "decided")
    assert_no_enqueued_jobs(only: CheckReviewRequestJob) { get project_reviews_path(@project) }
  end

  # Sedno ręcznego sprawdzenia: świeży stempel jest dokładnie tym, co blokuje index.
  test "recheck_github kolejkuje mimo świeżego cache" do
    review = reviews(:pr_review)
    review.update!(status: "decided", github_checked_at: 1.minute.ago)
    assert_enqueued_with(job: CheckReviewRequestJob, args: [ review ]) do
      post recheck_github_project_reviews_path(@project)
    end
    assert_redirected_to project_reviews_path(@project)
    assert_match(/Sprawdzam 1 review/, flash[:notice])
  end

  test "recheck_github odnawia stempel, więc drugi klik nie dubluje wywołań gh" do
    reviews(:pr_review).update!(status: "decided", github_checked_at: 2.hours.ago)
    post recheck_github_project_reviews_path(@project)
    assert_no_enqueued_jobs(only: CheckReviewRequestJob) do
      get project_reviews_path(@project)
    end
  end

  test "recheck_github pomija inne statusy i review bez PR-a" do
    reviews(:pr_review).update!(status: "reviewed")
    reviews(:task_only).update!(status: "decided")
    assert_no_enqueued_jobs(only: CheckReviewRequestJob) do
      post recheck_github_project_reviews_path(@project)
    end
    assert_match(/Nie ma review/, flash[:notice])
  end

  test "recheck_github nie rusza review innego projektu" do
    other = projects(:dashboard).reviews.create!(pr_url: "https://github.com/example/dashboard/pull/3",
                                                 status: "decided", github_checked_at: nil)
    reviews(:pr_review).update!(status: "decided")
    post recheck_github_project_reviews_path(@project)
    assert_nil other.reload.github_checked_at
  end

  # Filtr i sortowanie z adresu, na którym stał user, muszą przeżyć kliknięcie.
  test "recheck_github wraca tam, skąd przyszedł" do
    reviews(:pr_review).update!(status: "decided")
    from = project_reviews_path(@project, status: "decided", sort: "status")
    post recheck_github_project_reviews_path(@project), headers: { "HTTP_REFERER" => from }
    assert_redirected_to from
  end

  test "dashboard ma przycisk ręcznego sprawdzenia GitHuba" do
    get project_reviews_path(@project)
    assert_select "form[action=?][method=post]", recheck_github_project_reviews_path(@project)
  end

  test "lista subskrybuje kanał reviews i pokazuje etykietę statusu" do
    reviews(:pr_review).update!(status: "waiting_review")
    get project_reviews_path(@project)
    assert_select "turbo-cable-stream-source"
    assert_select "tr#review_row_#{reviews(:pr_review).id} .status-badge", text: "Czeka ponowne review"
  end

  test "show w waiting_review pokazuje followup z prefill-em, bez formularza decyzji" do
    review = reviews(:pr_review)
    review.update!(status: "waiting_review", summary: "Werdykt: OK")
    get review_path(review)
    assert_select "textarea[name=message]", text: /pobierz najnowszy stan brancha/
    assert_select "button[name=verdict]", count: 0
    assert_select "span.status-badge", text: "Czeka ponowne review"
  end

  test "show w decided pokazuje decyzję i ręczny followup do ponownego sprawdzenia" do
    review = reviews(:pr_review)
    review.update!(status: "decided", summary: "Werdykt: OK", decision: "approve", decided_at: Time.current)
    get review_path(review)
    assert_select "h2", text: "Decyzja: approve"
    assert_select "textarea[name=message]", text: /Pobierz najnowszy stan brancha/
  end

  test "create kolejkuje DescribeReviewJob i przekierowuje na show" do
    assert_enqueued_with(job: DescribeReviewJob) do
      post project_reviews_path(@project), params: { review: { pr_url: "https://github.com/acme/webapp/pull/9", claude_config: "/Users/dev/.claude" } }
    end
    review = Review.order(:id).last
    assert_redirected_to review_path(review)
    assert_equal "https://github.com/acme/webapp/pull/9", review.pr_url
  end

  # effective_claude_config nie sanityzuje: `claude_config.presence || project.default...`
  # zwraca surową wartość z formularza, gdy jest obecna — więc to walidacja na modelu,
  # nie kontroler, jest jedyną linią obrony przed dowolną ścieżką z params trafiającą
  # do CLAUDE_CONFIG_DIR spawnowanego procesu.
  test "create odrzuca claude_config spoza listy dostępnych configów" do
    assert_no_difference "Review.count" do
      post project_reviews_path(@project),
           params: { review: { pr_url: "https://github.com/acme/webapp/pull/9", claude_config: "/etc/passwd" } }
    end
    assert_response :unprocessable_entity
  end

  test "create z PR-em, który ma już review, pokazuje błąd z linkiem do istniejącego" do
    existing = reviews(:pr_review)
    assert_no_difference "Review.count" do
      post project_reviews_path(@project), params: { review: { pr_url: existing.pr_url } }
    end
    assert_response :unprocessable_entity
    assert_select ".flash-error a[href=?]", review_path(existing)
  end

  test "create z checkboxem kolejkuje opis zadania" do
    assert_enqueued_with(job: DescribeTaskJob) do
      post project_reviews_path(@project),
           params: { review: { pr_url: "https://github.com/acme/webapp/pull/77" }, fetch_task_description: "1" }
    end
    assert_equal "queued", Review.order(:id).last.task_description_status
  end

  test "create bez checkboxa zostawia skipped i nie kolejkuje" do
    assert_no_enqueued_jobs(only: DescribeTaskJob) do
      post project_reviews_path(@project),
           params: { review: { pr_url: "https://github.com/acme/webapp/pull/77" } }
    end
    assert_equal "skipped", Review.order(:id).last.task_description_status
  end

  test "formularz nowego review ma zaznaczony checkbox opisu zadania" do
    get new_project_review_path(@project)
    assert_select "input[name=fetch_task_description][checked]"
  end

  test "refresh_task_description kolejkuje ponownie" do
    review = reviews(:pr_review)
    review.update!(task_description_status: "ready", task_description: "stary")
    assert_enqueued_with(job: DescribeTaskJob) { post refresh_task_description_review_path(review) }
    assert_equal "queued", review.reload.task_description_status
  end

  test "refresh_task_description nie dubluje pracującego joba" do
    review = reviews(:pr_review)
    review.update!(task_description_status: "running")
    assert_no_enqueued_jobs(only: DescribeTaskJob) { post refresh_task_description_review_path(review) }
    assert_equal "running", review.reload.task_description_status
  end

  test "show pokazuje kartę opisu zadania w każdym stanie" do
    review = reviews(:pr_review)

    review.update!(task_description_status: "ready", task_description: "**Cel** — działa")
    get review_path(review)
    assert_select "details.card summary", text: "Opis zadania"
    assert_match "Cel", response.body

    review.update!(task_description_status: "running")
    get review_path(review)
    assert_match "Pobieram opis zadania", response.body

    review.update!(task_description_status: "failed")
    review.claude_runs.create!(kind: "describe_task", claude_config: review.effective_claude_config,
                               status: "failed", error_message: "brak dostępu do zadania")
    get review_path(review)
    assert_match "Nie udało się pobrać opisu zadania: brak dostępu do zadania", response.body
    assert_match "Ponów opis zadania", response.body
    assert_match "Cel", response.body, "stary opis zostaje widoczny mimo błędu odświeżania"

    review.update!(task_description_status: "skipped", task_description: nil)
    get review_path(review)
    assert_match "Generuj opis zadania", response.body
  end

  test "create bez linków renderuje błąd" do
    # branch: "" tylko po to, żeby hash `review` nie był literalnie pusty —
    # zupełnie pusty zagnieżdżony hash znika z body requestu w teście integracyjnym,
    # więc params.require(:review) dostałby brakujący klucz i skończyłoby się 400,
    # zamiast oczekiwanego 422 z walidacji "Podaj link".
    post project_reviews_path(@project), params: { review: { branch: "" } }
    assert_response :unprocessable_entity
    assert_select ".flash-error", text: /Podaj link/
  end

  test "show w statusie ready pokazuje rozwinięty opis i checkboxy zakresu" do
    review = reviews(:pr_review)
    review.update!(status: "ready", description: "PROSTY OPIS")
    get review_path(review)
    assert_response :success
    assert_select "details.card[open]", text: /PROSTY OPIS/
    assert_select "input[type=checkbox][name='areas[]']", count: Review::AREAS.size
  end

  # Opis znikał z ekranu po starcie review — a to jedyne miejsce w panelu,
  # gdzie widać, o co w zadaniu w ogóle chodziło.
  test "opis zostaje dostępny po starcie review, tylko zwinięty" do
    review = reviews(:pr_review)
    %w[reviewing reviewed failed].each do |status|
      review.update!(status: status, description: "PROSTY OPIS")
      get review_path(review)
      assert_select "details.card:not([open])", { text: /PROSTY OPIS/ }, "brak zwiniętego opisu w statusie #{status}"
    end
  end

  test "panel bez opisu nie pokazuje pustej karty" do
    get review_path(reviews(:pr_review))
    assert_select "details.card", count: 0
  end

  test "opis w markdownie renderuje się jako HTML, nie surowe gwiazdki" do
    review = reviews(:pr_review)
    review.update!(status: "ready", description: "**Ważne:** lista:\n- punkt\n- `kod`")
    get review_path(review)
    assert_select ".md strong", text: "Ważne:"
    assert_select ".md li", text: "punkt"
    assert_select ".md code", text: "kod"
  end

  test "ekran ready odtwarza poprzedni wybór checkboxów i notatki" do
    review = reviews(:pr_review)
    review.update!(status: "ready", description: "OPIS",
                   scope: { "areas" => %w[functionality], "notes" => "moje uwagi" })
    get review_path(review)
    assert_select "input[type=checkbox][name='areas[]'][value=functionality][checked]"
    assert_select "input[type=checkbox][name='areas[]'][value=ux]:not([checked])"
    assert_select "textarea[name=notes]", text: "moje uwagi"
  end

  test "start zapisuje scope i kolejkuje RunReviewJob" do
    review = reviews(:pr_review)
    review.update!(status: "ready", worktree_path: Dir.tmpdir)
    assert_enqueued_with(job: RunReviewJob) do
      post start_review_path(review), params: { areas: %w[functionality ux], notes: "uwaga na VAT" }
    end
    assert_equal({ "areas" => %w[functionality ux], "notes" => "uwaga na VAT", "inline_comments" => false },
                 review.reload.scope)
    assert_redirected_to review_path(review)
  end

  # Checkbox przy starcie nie jest samą domyślną wartością dla formularza decyzji —
  # włącza w prompcie wymóg podania linii obecnej w diffie.
  test "start zapamiętuje wybór komentarzy inline" do
    review = reviews(:pr_review)
    review.update!(status: "ready", worktree_path: Dir.tmpdir)
    post start_review_path(review), params: { areas: %w[functionality], inline_comments: "1" }
    assert review.reload.inline_comments?
  end

  test "formularz startu ma zaznaczony checkbox komentarzy inline" do
    review = reviews(:pr_review)
    review.update!(status: "ready")
    get review_path(review)
    assert_select "input[name=inline_comments][checked]"
  end

  test "start od razu przestawia review w reviewing, zanim job ruszy" do
    review = reviews(:pr_review)
    review.update!(status: "ready", worktree_path: Dir.tmpdir)
    post start_review_path(review), params: { areas: %w[functionality] }
    assert_equal "reviewing", review.reload.status
  end

  test "panel w toku mówi o czekaniu w kolejce, dopóki żadna sesja nie pracuje" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing")
    get review_path(review)
    assert_select ".progress-line", text: /Czeka w kolejce/
  end

  test "panel w toku pokazuje wiadomość pracującej sesji zamiast kolejki" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing")
    review.claude_runs.create!(kind: "review", claude_config: "/x", status: "running", last_message: "Czytam diff")
    get review_path(review)
    assert_select ".progress-line", text: /Czytam diff/
    assert_select ".progress-line", text: /Czeka w kolejce/, count: 0
  end

  test "panel podaje, od kiedy zadanie czeka w kolejce" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing")
    get review_path(review)
    assert_select ".progress-line", text: /W kolejce od: /
  end

  # Bez tego review, którego job nigdy nie ruszył, zostaje w „reviewing" na zawsze:
  # „Przerwij" nie ma czego zabić, a formularz startu jest już poza zasięgiem.
  test "panel czekający w kolejce daje wyjście awaryjne przyciskiem Ponów" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing", description: "OPIS")
    get review_path(review)
    assert_select "form[action=?]", retry_run_review_path(review)
  end

  test "panel z pracującą sesją nie proponuje Ponów — zostawiłby żywy proces" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing", description: "OPIS")
    review.claude_runs.create!(kind: "review", claude_config: "/x", status: "running", last_message: "Czytam diff")
    get review_path(review)
    assert_select "form[action=?]", retry_run_review_path(review), count: 0
  end

  test "panel nie pokazuje wiadomości zakończonej sesji jako bieżącego postępu" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing")
    review.claude_runs.create!(kind: "review", claude_config: "/x", status: "succeeded", last_message: "Stary wynik")
    get review_path(review)
    assert_select ".progress-line", text: /Stary wynik/, count: 0
    assert_select ".progress-line", text: /Czeka w kolejce/
  end

  test "show w statusie reviewed pokazuje findings i decyzję" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", summary: "OK")
    review.findings.create!(priority: "critical", title: "Nil na kwocie", body: "opis", file_location: "app/x.rb:1")
    get review_path(review)
    assert_select ".finding-critical", text: /Nil na kwocie/
    assert_select "form[action=?]", review_decision_path(review)
    assert_select "details summary", text: /Podgląd/
    assert_select "textarea[name=body]"
  end

  test "show w statusie failed pokazuje błąd i retry" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "timeout")
    get review_path(review)
    assert_select ".error-box", text: /timeout/
    assert_select "form[action=?]", retry_run_review_path(review)
  end

  test "start poza statusem ready jest odrzucany bez kolejkowania joba" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing")
    assert_no_enqueued_jobs(only: RunReviewJob) do
      post start_review_path(review), params: { areas: %w[functionality] }
    end
    assert_redirected_to review_path(review)
    assert_equal "reviewing", review.reload.status
  end

  test "abort bez działającego procesu pokazuje alert zamiast fałszywego potwierdzenia" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing")
    post abort_review_path(review)
    assert_redirected_to review_path(review)
    assert_equal "Nie ma działającego procesu do przerwania", flash[:alert]
  end

  test "abort zabija process group działającego runa" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing", worktree_path: Dir.tmpdir)
    review.claude_runs.create!(kind: "review", claude_config: "/x", status: "running", pid: 99_999)
    killed = []
    CommandRunner.stub :kill_group, ->(pid) { killed << pid } do
      post abort_review_path(review)
    end
    assert_equal [ 99_999 ], killed
    assert_redirected_to review_path(review)
  end

  test "retry po failed describe wraca do created i kolejkuje describe" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "x", description: nil)
    assert_enqueued_with(job: DescribeReviewJob) { post retry_run_review_path(review) }
    assert_equal "created", review.reload.status
  end

  test "retry po failed review wraca do ready (start ręcznie)" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "x", description: "OPIS")
    post retry_run_review_path(review)
    assert_equal "ready", review.reload.status
  end

  test "remove_worktree usuwa worktree i czyści ścieżkę na review" do
    review = reviews(:pr_review)
    review.update!(status: "decided", decision: "approve", branch: "sl-fix-vat", worktree_path: "/wt")
    removed = []
    stub_worktree_remove(->(branch) { removed << branch }) { post remove_worktree_review_path(review) }
    assert_equal [ "sl-fix-vat" ], removed
    assert_nil review.reload.worktree_path
    assert_redirected_to review_path(review)
  end

  # Bez rescue StandardError zła literówka we wzorcu komendy (KeyError z `format`,
  # nie WorktreeManager::Error) wywalałaby się jako 500 zamiast czytelnego alertu —
  # dokładnie ta sama luka co przy destroy, tylko bez ukrytego kasowania artefaktów.
  test "remove_worktree pokazuje komunikat zamiast 500, gdy komenda ma zły wzorzec" do
    review = reviews(:pr_review)
    review.update!(status: "decided", decision: "approve", branch: "sl-fix-vat", worktree_path: "/wt")
    review.project.update_column(:worktree_delete_command, "bin/wt %{brnach}")

    post remove_worktree_review_path(review)

    assert_redirected_to review_path(review)
    assert_match(/brnach/, flash[:alert])
    assert_equal "/wt", review.reload.worktree_path
  end

  test "reimport wczytuje result.json z dysku i ustawia reviewed" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "przerwane")
    FileUtils.mkdir_p(review.artifacts_dir)
    File.write(review.artifacts_dir.join("result.json"),
               { summary: "Z dysku", findings: [], playwright: nil }.to_json)
    post reimport_review_path(review)
    review.reload
    assert_equal({ status: "reviewed", summary: "Z dysku", error: nil },
                 { status: review.status, summary: review.summary, error: review.error_message })
  ensure
    FileUtils.rm_rf(review.artifacts_dir)
  end

  test "reimport bez pliku odtwarza wynik z raw_result w bazie" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "x",
                   raw_result: { summary: "Z bazy", findings: [], playwright: nil }.to_json)
    FileUtils.rm_rf(review.artifacts_dir)
    post reimport_review_path(review)
    assert_equal({ status: "reviewed", summary: "Z bazy" },
                 { status: review.reload.status, summary: review.summary })
  end

  test "reimport bez pliku i bez raw_result pokazuje alert" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "x", raw_result: nil)
    FileUtils.rm_rf(review.artifacts_dir)
    post reimport_review_path(review)
    assert_equal "Brak wyniku na dysku ani w bazie — nie ma czego wczytać", flash[:alert]
    assert_equal "failed", review.reload.status
  end

  test "destroy kasuje review i artefakty" do
    review = reviews(:pr_review)
    FileUtils.mkdir_p(review.artifacts_dir)
    assert_difference("Review.count", -1) { delete review_path(review) }
    assert_not File.exist?(review.artifacts_dir)
    assert_redirected_to project_reviews_path(@project)
  end

  test "destroy kasuje też worktree review" do
    review = reviews(:pr_review)
    review.update!(status: "decided", decision: "approve", branch: "sl-fix-vat", worktree_path: "/wt")
    removed = []
    stub_worktree_remove(->(branch) { removed << branch }) { delete review_path(review) }
    assert_equal [ "sl-fix-vat" ], removed
    assert_equal 0, Review.where(id: review.id).count
    assert_match(/worktree sl-fix-vat/, flash[:notice])
  end

  # Zepsuty docker/mysql nie może uwięzić review w dashboardzie — rekord znika,
  # ale user musi dostać do ręki nazwę worktree do ręcznego sprzątnięcia.
  test "destroy kasuje review nawet gdy usuwanie worktree padło, i ostrzega" do
    review = reviews(:pr_review)
    review.update!(status: "decided", decision: "approve", branch: "sl-fix-vat", worktree_path: "/wt")
    failing = ->(_branch) { raise WorktreeManager::Error, "docker nie odpowiada" }
    assert_difference("Review.count", -1) do
      stub_worktree_remove(failing) { delete review_path(review) }
    end
    assert_match(/worktree sl-fix-vat został — docker nie odpowiada/, flash[:alert])
  end

  test "destroy nie rusza worktree, gdy review pracował w głównym repo" do
    review = reviews(:pr_review)
    review.update!(status: "decided", decision: "approve", branch: "master",
                   worktree_path: @project.repo_path)
    called = []
    stub_worktree_remove(->(branch) { called << branch }) { delete review_path(review) }
    assert_empty called
  end

  test "lista oznacza zakończone review jako niewymagające akcji" do
    reviews(:pr_review).update!(status: "merged")
    get project_reviews_path(@project)
    assert_select "tr#review_row_#{reviews(:pr_review).id} .status-badge", text: "🎉 Zmergowany"
    assert_select "tr", text: /nie wymaga akcji/
  end

  test "show zmergowanego review pokazuje wynik bez followupa i bez decyzji do wysłania" do
    review = reviews(:pr_review)
    review.update!(status: "merged", decision: "comment", summary: "Werdykt: OK")
    get review_path(review)
    assert_select ".done-box", text: /nie wymaga żadnej akcji/
    assert_select "textarea[name=message]", count: 0
    assert_select "button[name=verdict]", count: 0
    assert_select ".card h2", text: "Decyzja: comment"
  end

  test "show zamkniętego PR-a mówi wprost, że nie było merge'a" do
    reviews(:pr_review).update!(status: "closed", decision: "reject", summary: "Werdykt: nie")
    get review_path(reviews(:pr_review))
    assert_select ".done-box", text: /zamknięty bez merge/
  end

  # Kliknięcie „Usuń" zabiera też środowisko dev — confirm musi to powiedzieć wprost,
  # zanim user je straci.
  test "confirm przy usuwaniu ostrzega o worktree, gdy review ma własne" do
    reviews(:pr_review).update!(status: "decided", decision: "approve", branch: "sl-fix-vat", worktree_path: "/wt")
    get project_reviews_path(@project)
    assert_select "form[data-turbo-confirm*=?]", "worktree sl-fix-vat (katalog i baza devowa)"
  end

  test "confirm bez worktree zostaje przy krótkiej treści" do
    reviews(:pr_review).update!(branch: nil, worktree_path: nil)
    get project_reviews_path(@project)
    assert_select "form[data-turbo-confirm=?]", "Usunąć review i wszystkie artefakty? Tego nie da się cofnąć."
  end

  # Po nieudanym ponowieniu ostatnia sesja bywa tą, która padła po kilku sekundach,
  # a cała praca została w poprzedniej — panel musi pokazać obie i czas trwania,
  # bo to jedyne, co je odróżnia.
  test "panel pokazuje wszystkie sesje do wznowienia razem z czasem trwania" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "limit", worktree_path: "/wt")
    review.claude_runs.create!(kind: "review", claude_config: "/c", status: "failed", session_id: "dluga",
                               started_at: 11.minutes.ago, finished_at: Time.current)
    review.claude_runs.create!(kind: "review", claude_config: "/c", status: "failed", session_id: "krotka",
                               started_at: 8.seconds.ago, finished_at: Time.current)
    get review_path(review)
    assert_select "code", text: /--resume dluga/
    assert_select "code", text: /--resume krotka/
    assert_select "details", text: /11 min/
    assert_select "details", text: /8 s/
  end

  test "panel bez sesji nie pokazuje pustej sekcji wznawiania" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "x")
    get review_path(review)
    assert_select "details summary", text: /Wróć do sesji/, count: 0
  end

  test "switch_config przełącza review na drugie konto i kopiuje sesje" do
    review = reviews(:pr_review)
    Dir.mktmpdir do |workdir|
      review.update!(status: "reviewed", worktree_path: workdir, claude_config: "/Users/dev/.claude")
      run = review.claude_runs.create!(kind: "review", claude_config: "/Users/dev/.claude",
                                       status: "succeeded", session_id: "sess-1")
      migrated = []
      migrator = Object.new
      migrator.define_singleton_method(:migrate_to) { |config| migrated << config; 1 }
      SessionMigrator.stub(:new, migrator) do
        post switch_config_review_path(review, claude_config: "/Users/dev/.claude-b")
      end
      assert_equal [ "/Users/dev/.claude-b" ], migrated
      assert_equal "/Users/dev/.claude-b", review.reload.claude_config
      assert_equal "/Users/dev/.claude", run.reload.claude_config, "historia runa zostaje nietknięta"
      assert_match(/config B/, flash[:notice])
    end
  end

  # Status razem z configiem, nie dopiero w jobie: między kolejkowaniem a startem
  # workera potrafi minąć kilkanaście minut, a panel pokazywałby przez ten czas
  # czerwony box „Błąd" z przyciskiem „Ponów" dla kroku, który już czeka w kolejce.
  test "switch_config po failed review ponawia review na nowym koncie" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "limit", worktree_path: Dir.tmpdir)
    review.claude_runs.create!(kind: "review", claude_config: "/Users/dev/.claude", status: "failed")
    stub_session_migrator do
      assert_enqueued_with(job: RunReviewJob, args: [ review ]) do
        post switch_config_review_path(review, claude_config: "/Users/dev/.claude-b")
      end
    end
    assert_equal "reviewing", review.reload.status
  end

  test "switch_config po failed describe ponawia describe" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "limit")
    review.claude_runs.create!(kind: "describe", claude_config: "/Users/dev/.claude", status: "failed")
    stub_session_migrator do
      assert_enqueued_with(job: DescribeReviewJob, args: [ review ]) do
        post switch_config_review_path(review, claude_config: "/Users/dev/.claude-b")
      end
    end
    assert_equal "describing", review.reload.status
  end

  test "switch_config po failed followupie powtarza go z tą samą uwagą" do
    review = reviews(:pr_review)
    review.update!(status: "failed", error_message: "limit", worktree_path: Dir.tmpdir)
    review.claude_runs.create!(kind: "followup", claude_config: "/Users/dev/.claude",
                               status: "failed", user_message: "to false positive")
    stub_session_migrator do
      assert_enqueued_with(job: FollowupReviewJob, args: [ review, "to false positive" ]) do
        post switch_config_review_path(review, claude_config: "/Users/dev/.claude-b")
      end
    end
    assert_equal "reviewing", review.reload.status
  end

  test "switch_config poza failed tylko przełącza, bez kolejkowania" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", summary: "OK", worktree_path: Dir.tmpdir)
    stub_session_migrator do
      assert_no_enqueued_jobs(only: [ RunReviewJob, DescribeReviewJob, FollowupReviewJob ]) do
        post switch_config_review_path(review, claude_config: "/Users/dev/.claude-b")
      end
    end
    assert_equal "/Users/dev/.claude-b", review.reload.claude_config
    assert_equal "reviewed", review.reload.status, "poza failed status zostaje nietknięty"
  end

  # Config trafia prosto do CLAUDE_CONFIG_DIR spawnowanego procesu — dowolna ścieżka
  # z formularza nie może przejść.
  test "switch_config odrzuca config spoza listy" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", claude_config: "/Users/dev/.claude")
    post switch_config_review_path(review, claude_config: "/etc")
    assert_equal "/Users/dev/.claude", review.reload.claude_config
    assert_match(/Nieznany config/, flash[:alert])
  end

  test "switch_config odmawia, gdy sesja jeszcze pracuje" do
    review = reviews(:pr_review)
    review.update!(status: "reviewing", claude_config: "/Users/dev/.claude")
    review.claude_runs.create!(kind: "review", claude_config: "/Users/dev/.claude", status: "running", pid: 1)
    post switch_config_review_path(review, claude_config: "/Users/dev/.claude-b")
    assert_equal "/Users/dev/.claude", review.reload.claude_config
    assert_match(/przerwij/i, flash[:alert])
  end

  test "switch_config odrzuca przełączenie na to samo konto" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", claude_config: "/Users/dev/.claude")
    post switch_config_review_path(review, claude_config: "/Users/dev/.claude")
    assert_equal "/Users/dev/.claude", review.reload.claude_config
    assert_match(/już jest aktywne/i, flash[:alert])
  end

  # Migracja to realne I/O na dysku (uprawnienia, brak miejsca) — awaria nie może
  # wywalić kontrolera 500-tką, tylko wrócić czytelnym alertem, a config ma zostać
  # bez zmian: przełączenie bez skopiowanych sesji zostawiłoby review w stanie,
  # o którym user nie wie, że followup ruszy świeżą sesją bez kontekstu.
  test "switch_config przy błędzie migracji nie przełącza configu i pokazuje czytelny alert" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", claude_config: "/Users/dev/.claude")
    migrator = Object.new
    migrator.define_singleton_method(:migrate_to) { |_config| raise Errno::EACCES, "Permission denied" }
    SessionMigrator.stub(:new, migrator) do
      post switch_config_review_path(review, claude_config: "/Users/dev/.claude-b")
    end
    assert_response :redirect
    assert_equal "/Users/dev/.claude", review.reload.claude_config, "config zostaje bez zmian po nieudanej migracji"
    assert_match(/nie udało się przenieść sesji/i, flash[:alert])
  end

  test "panel pokazuje bieżące konto i przycisk na drugie" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", summary: "OK", claude_config: "/Users/dev/.claude")
    get review_path(review)
    assert_select ".card", text: /config A/
    assert_select "form[action=?]", switch_config_review_path(review, claude_config: "/Users/dev/.claude-b")
  end

  test "panel zakończonego review nie proponuje zmiany konta" do
    reviews(:pr_review).update!(status: "merged", summary: "OK")
    get review_path(reviews(:pr_review))
    assert_select "form[action^=?]", switch_config_review_path(reviews(:pr_review)), count: 0
  end

  test "formularz nowego review ma zaznaczone defaulty projektu" do
    projects(:webapp).update!(default_claude_config: "/Users/dev/.claude-b",
                                   default_model: "opus", default_effort: "high")

    get new_project_review_path(projects(:webapp))
    assert_response :success
    assert_select "select[name='review[claude_config]'] option[selected][value=?]", "/Users/dev/.claude-b"
    assert_select "select[name='review[model]'] option[selected][value=?]", "opus"
    assert_select "select[name='review[effort]'] option[selected][value=?]", "high"
  end

  # GET .../reviews/new renderował pełny formularz nawet dla zarchiwizowanego
  # projektu, a walidacja (project_not_archived) odbijała się dopiero przy submit.
  # Przekierowanie od razu na GET pasuje do konwencji tego kontrolera (patrz start,
  # switch_config) i nie każe userowi wypełniać formularza, który i tak nie przejdzie.
  test "new przekierowuje z komunikatem, gdy projekt jest zarchiwizowany" do
    @project.update!(archived_at: Time.current)

    get new_project_review_path(@project)

    assert_redirected_to project_reviews_path(@project)
    assert_match(/zarchiwizowany/, flash[:alert])
  end

  test "formularz podpowiada adres PR-a z repozytorium projektu" do
    get new_project_review_path(projects(:webapp))
    assert_select "input[name='review[pr_url]'][placeholder=?]", "https://github.com/acme/webapp/pull/…"
  end

  # repo_url zakończony ukośnikiem albo .git przechodzi walidację Project (regexp go
  # zjada), ale sklejenie surowego repo_url z "/pull/…" dawało wtedy "//pull/…" albo
  # ".git/pull/…". github_slug jest już znormalizowany, więc placeholder zawsze
  # wygląda tak samo niezależnie od formy adresu w bazie.
  test "placeholder PR-a używa sluga repo, nie sklejonego surowego adresu" do
    [ "https://github.com/acme/webapp/", "https://github.com/acme/webapp.git" ].each do |repo_url|
      @project.update!(repo_url: repo_url)
      get new_project_review_path(@project)
      assert_select "input[name='review[pr_url]'][placeholder=?]", "https://github.com/acme/webapp/pull/…"
    end
  end

  test "nowy review odrzuca PR z innego repozytorium" do
    assert_no_difference "Review.count" do
      post project_reviews_path(projects(:webapp)),
           params: { review: { pr_url: "https://github.com/kto/inne/pull/1" } }
    end
    assert_response :unprocessable_entity
  end

  test "panel pokazuje zapełnienie kontekstu z procentem" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: "/c", context_tokens: 289_135, context_window: 1_000_000)
    get review_path(review)
    assert_select "div#review_#{review.id}_context" do
      assert_select ".ctx-fill"
      assert_select "p", text: /29%/
    end
  end

  test "panel bez sesji nie pokazuje karty kontekstu, ale zostawia cel broadcastu" do
    get review_path(reviews(:pr_review))
    assert_select "div#review_#{reviews(:pr_review).id}_context"
    assert_select ".ctx-bar", count: 0
  end

  # Po compakcie stary pomiar jest nieprawdą — karta ma to powiedzieć wprost,
  # zamiast pokazywać liczbę sprzed kompakcji.
  test "panel po compakcie mówi, że pomiaru jeszcze nie ma" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: "/c", context_tokens: 289_135, context_window: 1_000_000)
    review.claude_runs.create!(kind: "compact", claude_config: "/c", status: "succeeded",
                              last_message: "Not enough messages to compact.")
    get review_path(review)
    assert_select ".ctx-bar", count: 0
    assert_select "p", text: /zmierzy się przy następnej sesji/
    assert_select "p", text: /Not enough messages to compact\./
  end

  test "compact odmawia, gdy nie ma czego kompaktować" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed")
    assert_no_enqueued_jobs(only: CompactReviewJob) do
      post compact_review_path(review)
    end
    assert_redirected_to review_path(review)
    assert_equal "reviewed", review.reload.status
  end

  # Status musi zmienić się od razu, nie dopiero gdy worker zwolni wątek —
  # inaczej panel wygląda identycznie jak przed kliknięciem.
  test "compact przestawia status na reviewing i kolejkuje job z poprzednim statusem" do
    config = Dir.mktmpdir
    review = reviews(:pr_review)
    review.update!(status: "reviewed", worktree_path: Dir.tmpdir)
    # update_column: tmpdir testowy nie jest jednym z dwóch prawdziwych configów
    # z listy, więc walidacja inclusion nie ma tu czego pilnować.
    review.update_column(:claude_config, config)
    run = review.claude_runs.create!(kind: "review", claude_config: config, status: "succeeded", session_id: "sess-1")
    FileUtils.mkdir_p(run.session_file(config).dirname)
    File.write(run.session_file(config), "{}")

    assert_enqueued_with(job: CompactReviewJob, args: [ review, "reviewed" ]) do
      post compact_review_path(review)
    end
    assert_equal "reviewing", review.reload.status

    # Drugi klik przed startem workera: runu jeszcze nie ma, więc sam warunek
    # „nic nie działa" by go przepuścił i dwie kompakcje biłyby się o plik sesji.
    assert_no_enqueued_jobs(only: CompactReviewJob) do
      post compact_review_path(review)
    end
  ensure
    FileUtils.remove_entry(config)
  end

  private

  # Bez stuba SessionMigrator pisze do prawdziwych katalogów configów Claude
  # użytkownika. Dziś ratuje nas tylko to, że runy w tych testach nie mają session_id —
  # pierwszy test, który je doda, zacząłby kopiować pliki w realnym configu.
  def stub_session_migrator(copied: 0)
    migrator = Object.new
    migrator.define_singleton_method(:migrate_to) { |_config| copied }
    SessionMigrator.stub(:new, migrator) { yield }
  end

  def stub_worktree_remove(handler, &block)
    manager = Object.new
    manager.define_singleton_method(:remove) { |branch| handler.call(branch) }
    WorktreeManager.stub(:new, manager, &block)
  end

  # Kafel kolejki „czeka na Twoje review" prowadzi tu z adresem PR-a i linkiem do
  # zadania wyłuskanym z jego opisu — formularz ma je pokazać wpisane.
  test "should prefill the new-review form from the queue tile" do
    get new_project_review_path(@project, pr_url: "https://github.com/acme/webapp/pull/77",
                                          task_url: "https://tracker.example.com/organize/tasks/32586")

    assert_response :success
    assert_select "input[name='review[pr_url]'][value=?]", "https://github.com/acme/webapp/pull/77"
    assert_select "input[name='review[task_url]'][value=?]", "https://tracker.example.com/organize/tasks/32586"
  end

  # Liczniki nad tabelą mówią „ile tu jest roboty", więc liczą cały projekt — także
  # wtedy, gdy patrzysz na listę przefiltrowaną po statusie.
  test "should count the whole project above the list regardless of the filter" do
    reviews(:pr_review).update!(status: "reviewed")
    reviews(:task_only).update!(status: "reviewing")

    get project_reviews_path(@project, status: "reviewed")

    assert_select "table#reviews tbody tr", count: 1
    assert_select ".pill-attention", text: /1 czeka na Ciebie/
    assert_select ".pill-progress", text: /1 w toku/
  end

  # Pusta tabela bez słowa wygląda jak zepsuta strona, a najczęstszą przyczyną jest
  # filtr statusu — komunikat musi więc podać drogę powrotną.
  test "should explain an empty list and offer a way back from the filter" do
    get project_reviews_path(@project, status: "merged")

    assert_select ".empty", text: /Żadne review nie ma statusu/
    assert_select ".empty a[href=?]", project_reviews_path(@project), text: "Pokaż wszystkie"
  end

  test "should explain an empty project without blaming a filter" do
    @project.reviews.destroy_all

    get project_reviews_path(@project)

    assert_select ".empty", text: /Jeszcze żadnego review/
    assert_select ".empty a", count: 0
  end

  # button_to renderuje blokowy <form>, więc bez wspólnego paska każdy przycisk zjeżdżał
  # do osobnej linii — pasek akcji ma być jeden.
  test "should keep the project actions and the status filter in one bar" do
    get project_reviews_path(@project)

    assert_select ".toolbar a[href=?]", new_project_review_path(@project)
    assert_select ".toolbar form[action=?]", recheck_github_project_reviews_path(@project)
    assert_select ".toolbar form.filter select[name=status]"
  end

  # Tytuły PR-ów w jednym projekcie bywają bliźniacze — wiersz musi mówić, której
  # zmiany dotyczy.
  test "should name the PR and branch under the title" do
    reviews(:pr_review).update!(pr_number: 1234, branch: "sl-fix-vat", model: "opus")

    get project_reviews_path(@project)

    assert_select "tr#review_row_#{reviews(:pr_review).id} td.title-cell .muted",
                  text: /PR #1234 · sl-fix-vat · opus/
  end
end
