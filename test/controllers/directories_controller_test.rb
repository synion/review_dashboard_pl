require "test_helper"

class DirectoriesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @project = projects(:webapp)
    DirectoryEntry.replace!(@project, "intum_user", [ { external_id: "1", name: "Anna Kowalska" },
                                                      { external_id: "2", name: "Jan Nowak" } ])
  end

  test "zwraca podpowiedzi filtrowane po q" do
    get directory_project_path(@project, kind: "intum_user", q: "kowal")

    assert_response :success
    assert_equal [ { "id" => "1", "name" => "Anna Kowalska" } ], response.parsed_body
  end

  test "odrzuca nieznany kind" do
    get directory_project_path(@project, kind: "wrong", q: "x")
    assert_response :unprocessable_entity
  end

  test "stęchły cache zleca odświeżenie w tle, ale odpowiada od razu" do
    @project.directory_entries.update_all(refreshed_at: 2.days.ago)

    assert_enqueued_with(job: RefreshDirectoryJob) do
      get directory_project_path(@project, kind: "intum_user", q: "")
    end
    assert_response :success
  end

  test "świeży cache nie zleca odświeżenia" do
    @project.directory_entries.update_all(refreshed_at: 5.minutes.ago)

    assert_no_enqueued_jobs do
      get directory_project_path(@project, kind: "intum_user", q: "")
    end
  end

  test "refresh_directory zleca job i wraca do projektu" do
    assert_enqueued_with(job: RefreshDirectoryJob) do
      post refresh_directory_project_path(@project)
    end
    assert_redirected_to edit_project_path(@project)
  end
end
