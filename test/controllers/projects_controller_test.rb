require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  test "index renderuje listę projektów" do
    get root_path
    assert_response :success
    assert_select "table#projects tbody tr", count: Project.active.count
  end

  test "kubełki liczników liczą failed jako czeka na Ciebie, a reviewing jako w toku" do
    project = projects(:webapp)
    reviews(:pr_review).update!(status: "failed")
    reviews(:task_only).update!(status: "reviewing")

    get root_path

    assert_select "tr#project_row_#{project.id} td:nth-child(2)", text: "1"
    assert_select "tr#project_row_#{project.id} td:nth-child(3)", text: "1"
    assert_select "tr#project_row_#{project.id} td:nth-child(4)", text: "2"
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

    assert_select "tr#project_row_#{project.id} td:nth-child(2)", text: "0"
    assert_select "tr#project_row_#{project.id} td:nth-child(3)", text: "2"
  end

  test "projekt bez żadnego review pokazuje same zera" do
    project = projects(:dashboard)
    assert_equal 0, project.reviews.count, "test ma sens tylko przy projekcie bez review"

    get root_path

    assert_select "tr#project_row_#{project.id} td:nth-child(2)", text: "0"
    assert_select "tr#project_row_#{project.id} td:nth-child(3)", text: "0"
    assert_select "tr#project_row_#{project.id} td:nth-child(4)", text: "0"
  end

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
    assert_select "table#projects form[action=?][data-turbo-confirm]", archive_project_path(projects(:webapp))
  end

  test "archiwizuje projekt i zdejmuje go z listy aktywnych" do
    post archive_project_path(projects(:dashboard))
    assert_redirected_to projects_path
    assert projects(:dashboard).reload.archived?

    get root_path
    assert_select "table#projects tr#project_row_#{projects(:dashboard).id}", count: 0
    assert_select "table#archived_projects tr#project_row_#{projects(:dashboard).id}", count: 1
  end

  test "przywraca zarchiwizowany projekt" do
    projects(:dashboard).update!(archived_at: Time.current)
    post unarchive_project_path(projects(:dashboard))
    assert_redirected_to projects_path
    assert_not projects(:dashboard).reload.archived?
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

  # Kolejka „czeka na Twoje review" to piłka z GitHuba na CZYIMŚ PR-ze — review
  # założone w dashboardzie mają swoje liczniki i nie mieszają się do tej sekcji.
  test "should list PRs waiting for my review" do
    inbox_items(:commented).destroy
    reviews(:pr_review).update!(status: "reviewed")

    get root_path

    assert_select "#attention tbody tr", count: 1
    assert_select "#attention #inbox_pr_9001"
  end

  test "should put review requests above post-review comments" do
    get root_path

    assert_equal %w[inbox_pr_9001 inbox_pr_9002],
                 css_select("#attention tbody tr").map { |row| row["id"] }
  end

  test "should offer to start a review for a PR the dashboard has never seen" do
    item = inbox_items(:requested)

    get root_path

    assert_select "#inbox_pr_9001 a[href=?]",
                  new_project_review_path(item.project, pr_url: item.url), text: /Zleć review/
  end

  test "should hand the task link over to the new-review form" do
    item = inbox_items(:requested)
    item.update!(task_url: "https://tracker.example.com/organize/tasks/32586")

    get root_path

    assert_select "#inbox_pr_9001 a[href=?]",
                  new_project_review_path(item.project, pr_url: item.url, task_url: item.task_url)
  end

  test "should link to the existing review when the PR is already in the dashboard" do
    item = inbox_items(:requested)
    reviews(:pr_review).update!(pr_number: item.pr_number, status: "reviewing")

    get root_path

    assert_select "#inbox_pr_9001 a[href=?]", review_path(reviews(:pr_review)), text: /Otwórz review/
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

    assert_select ".empty", text: /Nikt nie czeka/
  end

  # Bez tego rozróżnienia pusta kolejka po świeżej instalacji wyglądałaby jak
  # „nikt nie czeka", zamiast „jeszcze nie pytaliśmy GitHuba".
  test "should distinguish an empty queue from one never fetched" do
    InboxItem.delete_all

    get root_path

    assert_select ".empty", text: /jeszcze nie odpytany/
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
end
