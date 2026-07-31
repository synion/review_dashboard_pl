require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  # Kolejki strony wejściowej pokazują wyłącznie projekt główny, a fixture'owe
  # inbox itemy i review należą do webapp — bez tego fallback (pierwszy po nazwie)
  # wskazywałby review-dashboard i wszystkie testy kolejek oglądałyby pustkę.
  setup do
    projects(:webapp).update!(main_at: Time.current)
  end

  test "index renderuje listę projektów" do
    get root_path
    assert_response :success
    assert_select "#projects .projcard", count: Project.active.count
  end

  test "kubełki liczników liczą failed jako czeka na Ciebie, a reviewing jako w toku" do
    project = projects(:webapp)
    reviews(:pr_review).update!(status: "failed")
    reviews(:task_only).update!(status: "reviewing")

    get root_path

    assert_select "#project_row_#{project.id} [data-count=attention]", text: "1"
    assert_select "#project_row_#{project.id} [data-count=in_progress]", text: "1"
    assert_select "#project_row_#{project.id} [data-count=total]", text: "2"
  end

  # Fixtures stoją domyślnie w "created" — to okno między ReviewsController#create
  # a startem DescribeReviewJob, które potrafi trwać kilkanaście minut. Lista ma
  # odpowiadać na pytanie „gdzie mam pracę", więc review nie może w tym czasie
  # zniknąć z obu kubełków i być widoczne tylko w „Wszystkich".
  test "review w statusie created liczy się jako w toku, nie czeka na Ciebie" do
    project = projects(:webapp)
    assert_equal "created", reviews(:pr_review).status
    assert_equal "created", reviews(:task_only).status

    get root_path

    assert_select "#project_row_#{project.id} [data-count=attention]", text: "0"
    assert_select "#project_row_#{project.id} [data-count=in_progress]", text: "2"
  end

  test "projekt bez żadnego review pokazuje same zera" do
    project = projects(:dashboard)
    assert_equal 0, project.reviews.count, "test ma sens tylko przy projekcie bez review"

    get root_path

    assert_select "#project_row_#{project.id} [data-count=attention]", text: "0"
    assert_select "#project_row_#{project.id} [data-count=in_progress]", text: "0"
    assert_select "#project_row_#{project.id} [data-count=total]", text: "0"
  end

  # Nie „dokładnie N zapytań", a „liczba nie rośnie z liczbą projektów": strona
  # ładuje też kolejki review, więc sztywna liczba pilnowałaby przypadkowego
  # szczegółu implementacji zamiast realnego N+1.
  test "index nie mnoży zapytań o review z liczbą projektów" do
    count_queries = lambda do
      queries = 0
      counter = ->(*, payload) { queries += 1 if payload[:sql].include?("FROM \"reviews\"") }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get root_path }
      queries
    end
    before = count_queries.call

    3.times do |i|
      Project.create!(name: "extra#{i}", repo_path: Dir.tmpdir,
                      default_claude_config: Review::CLAUDE_CONFIGS.first.last,
                      worktree_command: "git worktree add ../%{branch} %{branch}")
    end

    assert_equal before, count_queries.call
  end

  test "tworzy projekt" do
    assert_difference "Project.count", 1 do
      post projects_path, params: { project: {
        name: "nowy", repo_path: Dir.tmpdir, repo_url: "https://github.com/kto/nowy",
        default_claude_config: "/Users/dev/.claude", default_model: "opus",
        default_effort: "high", docs_path: "doc/llm", worktree_command: "git worktree add ../%{branch} %{branch}"
      } }
    end
    project = Project.find_by(name: "nowy")
    assert_redirected_to project_reviews_path(project)
    assert_equal "opus", project.default_model
  end

  test "new renderuje formularz nowego projektu" do
    get new_project_path
    assert_response :success
    assert_select "form"
  end

  test "nie tworzy projektu z configiem Claude spoza listy" do
    assert_no_difference "Project.count" do
      post projects_path, params: { project: {
        name: "zły", repo_path: "/tmp/zly", default_claude_config: "/etc",
        worktree_command: "git worktree add ../%{branch} %{branch}"
      } }
    end
    assert_response :unprocessable_entity
  end

  test "aktualizuje projekt" do
    patch project_path(projects(:webapp)), params: { project: { default_effort: "max" } }
    assert_redirected_to project_reviews_path(projects(:webapp))
    assert_equal "max", projects(:webapp).reload.default_effort
  end

  test "aktualizacja z błędnymi danymi renderuje edit i zwraca 422" do
    patch project_path(projects(:webapp)), params: { project: { default_claude_config: "/etc" } }
    assert_response :unprocessable_entity
    assert_select "form"
    assert_not_equal "/etc", projects(:webapp).reload.default_claude_config
  end

  test "formularz edycji pokazuje aktualne ustawienia" do
    get edit_project_path(projects(:webapp))
    assert_response :success
    assert_select "input[name='project[repo_url]'][value=?]", "https://github.com/acme/webapp"
  end

  test "projektów się nie usuwa" do
    # Asercja to 404, nie wyjątek: test.rb ma show_exceptions = :rescuable
    # (domyślne w Rails 8), więc RoutingError zostaje przechwycony przez middleware
    # i zrenderowany jako strona 404, zamiast przelecieć do testu integracyjnego.
    # To wciąż prawdziwe żądanie przez cały stack — dowodzi zachowania widocznego
    # dla klienta (bezpieczne 404, projekt nietknięty), a nie tylko braku wpisu
    # w tablicy tras.
    assert_no_difference "Project.count" do
      delete "/projects/#{projects(:webapp).id}"
    end
    assert_response :not_found
  end

  # Każdy inny przycisk zmieniający stan w tej aplikacji ma potwierdzenie
  # (patrz review_destroy_confirm w _review_row.html.erb) — Archiwizuj nie powinien
  # być wyjątkiem, mimo że sam w sobie nic nie kasuje (dane zostają, tylko znikają z oczu).
  test "przycisk archiwizacji ma potwierdzenie" do
    get root_path
    assert_select "#projects form[action=?][data-turbo-confirm]", archive_project_path(projects(:webapp))
  end

  test "archiwizuje projekt i zdejmuje go z listy aktywnych" do
    post archive_project_path(projects(:dashboard))
    assert_redirected_to projects_path
    assert projects(:dashboard).reload.archived?

    get root_path
    assert_select "#projects #project_row_#{projects(:dashboard).id}", count: 0
    assert_select "#archived_projects #project_row_#{projects(:dashboard).id}", count: 1
  end

  test "przywraca zarchiwizowany projekt" do
    projects(:dashboard).update!(archived_at: Time.current)
    post unarchive_project_path(projects(:dashboard))
    assert_redirected_to projects_path
    assert_not projects(:dashboard).reload.archived?
  end

  # Archiwum zdejmuje projekt z oczu — jego review nie mogą wracać na stronę
  # wejściową przez kolejki „do dokończenia" / „w toku" ani zawyżać pigułek.
  test "review zarchiwizowanego projektu nie wchodzą do kolejek strony wejściowej" do
    reviews(:pr_review).update!(status: "failed")
    projects(:webapp).update!(archived_at: Time.current)

    get root_path

    assert_select "#review_queue_#{reviews(:pr_review).id}", count: 0
    assert_select ".pill", text: /0 do dokończenia/
  end

  test "dashboard zarchiwizowanego projektu nie proponuje nowego review" do
    projects(:webapp).update!(archived_at: Time.current)
    get project_reviews_path(projects(:webapp))
    assert_response :success
    assert_select "a", text: "+ Nowy review", count: 0
  end

  # Bez tego jedyna droga do przywrócenia projektu prowadzi przez /projects
  # i przewinięcie do „Zarchiwizowane" — a przycisk „+ Nowy review" po prostu
  # znika bez żadnego wyjaśnienia, dlaczego.
  test "dashboard zarchiwizowanego projektu tłumaczy dlaczego i pozwala przywrócić" do
    project = projects(:webapp)
    project.update!(archived_at: Time.current)

    get project_reviews_path(project)

    assert_response :success
    assert_select ".archived-notice", text: /zarchiwizowany/
    assert_select ".archived-notice form[action=?]", unarchive_project_path(project)
  end

  # „Czeka na Ciebie" = piłka z GitHuba na CZYIMŚ PR-ze. Stany dashboardu (decyzja
  # do wysłania, padnięta sesja) to moja robota, a nie cudze oczekiwanie — mają
  # osobną sekcję i nie wolno im wracać do kolejki z GitHuba.
  test "should list only GitHub signals in the waiting-for-you queue" do
    inbox_items(:commented).destroy
    reviews(:pr_review).update!(status: "reviewed")

    get root_path

    assert_select "#attention .qitem", count: 1
    assert_select "#attention #inbox_pr_9001"
    assert_select "#dashboard_work #review_queue_#{reviews(:pr_review).id}"
  end

  test "should put review requests above post-review comments" do
    inbox_items(:requested, :commented)

    get root_path

    assert_equal %w[inbox_pr_9001 inbox_pr_9002],
                 css_select("#attention .qitem").map { |item| item["id"] }
  end

  test "should offer to start a review for a PR the dashboard has never seen" do
    item = inbox_items(:requested)

    get root_path

    assert_select "##{"inbox_pr_9001"} a[href=?]",
                  new_project_review_path(item.project, pr_url: item.url), text: /Zleć review/
  end

  test "should link to the existing review when the PR is already in the dashboard" do
    item = inbox_items(:requested)
    reviews(:pr_review).update!(pr_number: item.pr_number, status: "reviewing")

    get root_path

    # Kafel przejmuje stan i następny krok istniejącego review — inaczej ta sama robota
    # stałaby drugi raz niżej, w „Rozpoczęte w dashboardzie".
    assert_select "#inbox_pr_9001 a[href=?]", review_path(reviews(:pr_review)),
                  text: /Sesja review pracuje/
    assert_select "#inbox_pr_9001 a", text: /Zleć review/, count: 0
  end

  test "should show how long each GitHub signal has been waiting" do
    inbox_items(:requested).update!(signal_at: 3.days.ago)

    get root_path

    assert_select "#inbox_pr_9001 .qwait", text: /czeka 3 dni/
  end

  test "should say plainly when nobody waits for my review" do
    InboxItem.delete_all
    Project.update_all(inbox_checked_at: Time.current)

    get root_path

    assert_select "#attention .empty", text: /Nikt nie czeka/
  end

  # Bez tego rozróżnienia pusty raport po świeżej instalacji wyglądałby jak
  # „nikt nie czeka", zamiast „jeszcze nie pytaliśmy GitHuba".
  test "should distinguish an empty queue from one never fetched" do
    InboxItem.delete_all
    projects(:webapp).update_columns(inbox_checked_at: nil)
    projects(:dashboard).update_columns(inbox_checked_at: nil)

    get root_path

    assert_select "#attention .empty", text: /jeszcze nie odpytany/
  end

  test "should refresh a stale queue in the background and leave a fresh one alone" do
    projects(:webapp).update_columns(inbox_checked_at: 1.hour.ago)
    projects(:dashboard).update_columns(inbox_checked_at: Time.current, repo_url: nil)

    assert_enqueued_with job: RefreshInboxJob, args: [ projects(:webapp) ] do
      get root_path
    end
  end

  test "should let me force a GitHub check from the page" do
    # Po jednym jobie na projekt z adresem repo — oba fixture'owe je mają.
    assert_enqueued_jobs Project.active.with_repo.count, only: RefreshInboxJob do
      post refresh_inbox_projects_path
    end
    assert_redirected_to projects_path
  end

  test "should keep running reviews in their own section" do
    reviews(:pr_review).update!(status: "reviewing")
    reviews(:task_only).update!(status: "describing")

    get root_path

    assert_select "#dashboard_work", count: 0
    assert_select "#in_progress .qitem", count: 2
  end

  test "should show how long a dashboard review has been waiting" do
    reviews(:pr_review).update!(status: "reviewed", updated_at: 3.days.ago)
    reviews(:task_only).update!(status: "merged")

    get root_path

    assert_select "#review_queue_#{reviews(:pr_review).id}", text: /3 dni/
  end

  test "should name the project on every waiting review" do
    reviews(:pr_review).update!(status: "reviewed")

    get root_path

    assert_select "#review_queue_#{reviews(:pr_review).id}", text: /webapp/
  end

  # Sedno switchera: kolejki różnych projektów nie mogą się mieszać. Po zmianie
  # projektu głównego rzeczy webappa (inbox z GH i review) znikają z widoku.
  test "kolejki pokazują wyłącznie projekt główny" do
    reviews(:pr_review).update!(status: "reviewed")
    projects(:dashboard).update!(main_at: Time.current)

    get root_path

    assert_select "#attention .qitem", count: 0
    assert_select "#dashboard_work", count: 0
    assert_select "#summary .proj-switcher .is-main button", text: "review-dashboard"
  end

  test "select ustawia projekt główny i odpowiada turbo_stream z kolejkami, pigułami i gridem" do
    post select_projects_path(project_id: projects(:dashboard).id), as: :turbo_stream

    assert_response :success
    assert_equal projects(:dashboard), Project.main
    %w[summary queues projects].each do |target|
      assert_match %(turbo-stream action="replace" target="#{target}"), response.body
    end
  end

  test "select nie przyjmuje zarchiwizowanego projektu" do
    projects(:dashboard).update!(archived_at: Time.current)

    post select_projects_path(project_id: projects(:dashboard).id), as: :turbo_stream

    assert_response :not_found
  end

  # Dwa uchwyty tego samego wyboru: switcher u góry i radio na karcie muszą
  # wskazywać ten sam projekt.
  test "radio na karcie i switcher u góry oznaczają projekt główny" do
    get root_path

    assert_select "#project_row_#{projects(:webapp).id} input[type=radio][checked]"
    assert_select "#project_row_#{projects(:dashboard).id} input[type=radio][checked]", count: 0
    assert_select "#summary .proj-switcher .is-main button", text: "webapp"
    assert_select "#summary .proj-switcher form", count: Project.active.count
  end

  test "should offer a new review straight from the project card" do
    project = projects(:webapp)

    get root_path

    assert_select "#project_row_#{project.id} a[href=?]", new_project_review_path(project)
    assert_select "#project_row_#{project.id} a[href=?]", project_reviews_path(project)
  end

  # Zarchiwizowane projekty są rzadko potrzebne, ale ich sekcja nie może wyglądać
  # jak druga, równorzędna lista projektów — stąd zwinięte <details>.
  test "should fold archived projects away" do
    projects(:dashboard).update!(archived_at: Time.current)

    get root_path

    assert_select "details#archived_projects"
  end

  # Jeden PR = jedna karta: review, którego PR wisi w kolejce z GitHuba, nie może wracać
  # niżej w drugiej sekcji z innym zegarem („czeka 12 godz." vs „czeka 6 godz.").
  test "should show a PR from the GitHub queue only once" do
    item = inbox_items(:requested)
    review = reviews(:pr_review)
    review.update!(pr_number: item.pr_number, status: "reviewed", summary: "OK")
    review.findings.create!(priority: "critical", title: "nil w kalkulacji", body: "x")

    get root_path

    assert_select "#attention #inbox_pr_#{item.pr_number}"
    assert_select "#dashboard_work #review_queue_#{review.id}", count: 0
    # Stan i znaleziska nie mogą przy tym przepaść — kafel je przejmuje.
    assert_select "#inbox_pr_#{item.pr_number} .qmeta", text: /Review zakończony · 1 znalezisko/
    assert_select "#inbox_pr_#{item.pr_number} .qact", text: /wyślij decyzję/
  end

  test "should keep dashboard-only work in its own section" do
    InboxItem.delete_all
    reviews(:pr_review).update!(status: "reviewed", summary: "OK")

    get root_path

    assert_select "#dashboard_work #review_queue_#{reviews(:pr_review).id}"
  end

  test "should shorten the home directory in a project path and keep the full one in the tooltip" do
    project = projects(:dashboard)
    project.update_columns(repo_path: File.join(Dir.home, "repos", "cokolwiek"))

    get root_path

    assert_select "#project_row_#{project.id} .projpath", text: "~/repos/cokolwiek"
    assert_select "#project_row_#{project.id} .projpath[title=?]", project.repo_path
  end

  test "should offer adding a project without competing with the per-project action" do
    get root_path

    # Kafel „dodaj" nie może być .projcard — liczniki kart liczą projekty.
    assert_select ".projgrid .projcard-add[href=?]", new_project_path
    assert_select ".projgrid .projcard-add.projcard", count: 0
  end

  test "should keep self reviews out of the home queues and attention counters" do
    InboxItem.delete_all
    project = projects(:webapp)
    self_review = Review.create!(project: project, branch: "sw-selfreview", status: "reviewed")

    get root_path

    assert_select "#review_queue_#{self_review.id}", count: 0
    assert_select "#project_row_#{project.id} [data-count=attention]", text: "0"
    # „łącznie" liczy wszystko — selfreview jest w projekcie, tylko nie woła o uwagę.
    assert_select "#project_row_#{project.id} [data-count=total]", text: "3"
  end

  # Weryfikacja uwag nie zmienia statusu review, więc kafle strony wejściowej
  # muszą dostać ten sygnał osobno — inaczej wygląda, jakby nic się nie działo.
  test "should show the running findings verification on the home tiles" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", branch: "sl-fix-vat", summary: "OK", pr_number: 9001,
                   pr_url: "https://github.com/acme/webapp/pull/9001")
    review.findings.create!(priority: "critical", title: "nil w kalkulacji", body: "x")
    review.claude_runs.create!(kind: "verify_findings", claude_config: "/Users/dev/.claude")

    get root_path
    assert_select "#inbox_pr_9001 .queued-hint", text: /weryfikacja uwag w toku/

    InboxItem.destroy_all
    get root_path
    assert_select "#dashboard_work #review_queue_#{review.id} .queued-hint", text: /weryfikacja uwag w toku/
  end

  test "puste pole tokena przy zapisie nie kasuje zapisanego tokena" do
    project = projects(:webapp)
    project.update!(intum_api_token: "stary-token")

    patch project_path(project), params: { project: { name: project.name, intum_api_token: "" } }

    assert_equal "stary-token", project.reload.intum_api_token
  end

  test "niepuste pole tokena podmienia token" do
    project = projects(:webapp)
    project.update!(intum_api_token: "stary-token")

    patch project_path(project), params: { project: { name: project.name, intum_api_token: "nowy-token" } }

    assert_equal "nowy-token", project.reload.intum_api_token
  end

  test "test_intum bez konfiguracji odsyła z alertem" do
    post test_intum_project_path(projects(:webapp))
    assert_redirected_to edit_project_path(projects(:webapp))
    assert_match(/Najpierw zapisz/, flash[:alert])
  end

  test "test_intum pokazuje liczbę osób przy działającym tokenie" do
    project = projects(:webapp)
    project.update!(task_url_prefix: "https://tracker.example.com/organize/tasks/", intum_api_token: "t")
    fake = Object.new
    fake.define_singleton_method(:users) { [ { "id" => "1", "name" => "Anna" } ] }

    IntumClient.stub :new, fake do
      post test_intum_project_path(project)
    end

    assert_match(/1 osób/, flash[:notice])
  end

  test "test_intum tłumaczy błąd klienta na alert" do
    project = projects(:webapp)
    project.update!(task_url_prefix: "https://tracker.example.com/organize/tasks/", intum_api_token: "t")
    fake = Object.new
    fake.define_singleton_method(:users) { raise IntumClient::Error, "tracker odpowiedział 403" }

    IntumClient.stub :new, fake do
      post test_intum_project_path(project)
    end

    assert_match(/403/, flash[:alert])
  end
end
