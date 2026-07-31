require "test_helper"

class RefreshDirectoryJobTest < ActiveSupport::TestCase
  class FakeGithub
    def initialize(collaborators: [], labels: [], error: nil)
      @collaborators, @labels, @error = collaborators, labels, error
    end

    def collaborators(repo:, repo_dir:)
      raise GithubClient::Error, @error if @error
      @collaborators
    end

    def labels(repo_dir:)
      raise GithubClient::Error, @error if @error
      @labels
    end
  end

  setup do
    @project = projects(:webapp)
  end

  test "zapisuje collaboratorów i labelki do directory_entries" do
    fake = FakeGithub.new(collaborators: %w[anna], labels: %w[bug])
    RefreshDirectoryJob.perform_now(@project, github: fake)

    assert_equal [ "anna" ], @project.directory_entries.where(kind: "gh_collaborator").pluck(:name)
    assert_equal [ "bug" ], @project.directory_entries.where(kind: "gh_label").pluck(:name)
  end

  test "projekt bez repo_url nie pyta GitHuba" do
    @project.update!(repo_url: nil)
    RefreshDirectoryJob.perform_now(@project, github: FakeGithub.new(error: "nie wolno"))

    assert_equal 0, @project.directory_entries.count
  end

  test "błąd gh nie wybucha i nie kasuje starego cache" do
    DirectoryEntry.replace!(@project, "gh_label", [ { external_id: "stary", name: "stary" } ])
    RefreshDirectoryJob.perform_now(@project, github: FakeGithub.new(error: "gh padł"))

    assert_equal [ "stary" ], @project.directory_entries.where(kind: "gh_label").pluck(:name)
  end

  class FakeIntum
    def initialize(users: [], error: nil)
      @users, @error = users, error
    end

    def users
      raise IntumClient::Error, @error if @error
      @users
    end
  end

  def enable_intum!
    @project.update!(task_url_prefix: "https://tracker.example.com/organize/tasks/", intum_api_token: "t")
  end

  test "projekt z tokenem trackera zapisuje też osoby (intum_user)" do
    enable_intum!
    fake_intum = FakeIntum.new(users: [ { "id" => "7", "name" => "Anna Kowalska" } ])
    RefreshDirectoryJob.perform_now(@project, github: FakeGithub.new, intum: fake_intum)

    assert_equal [ %w[7 Anna\ Kowalska] ],
                 @project.directory_entries.where(kind: "intum_user").pluck(:external_id, :name)
  end

  test "błąd trackera nie wybucha i nie psuje części GH" do
    enable_intum!
    RefreshDirectoryJob.perform_now(@project, github: FakeGithub.new(collaborators: %w[anna]),
                                    intum: FakeIntum.new(error: "tracker padł"))

    assert_equal [ "anna" ], @project.directory_entries.where(kind: "gh_collaborator").pluck(:name)
    assert_equal 0, @project.directory_entries.where(kind: "intum_user").count
  end

  test "refreshable? dla intum_user wymaga włączonej integracji" do
    assert_not RefreshDirectoryJob.refreshable?(@project, "intum_user")
    enable_intum!
    assert RefreshDirectoryJob.refreshable?(@project, "intum_user")
  end
end
