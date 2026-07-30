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

  test "index liczy review jednym zapytaniem niezależnie od liczby projektów" do
    queries = 0
    counter = ->(*, payload) { queries += 1 if payload[:sql].include?("FROM \"reviews\"") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get root_path }
    assert_equal 1, queries
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
end
