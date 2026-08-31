require "test_helper"

class PrSnapshotTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :calls

    def initialize(files: [], review_comments: [], issue_comments: [])
      @data = { files: files, review_comments: review_comments, issue_comments: issue_comments }
      @calls = []
    end

    def pr_files(url, repo_dir:) = record(:files, url, repo_dir)
    def pr_review_comments(url, repo_dir:) = record(:review_comments, url, repo_dir)
    def pr_issue_comments(url, repo_dir:) = record(:issue_comments, url, repo_dir)

    private

    def record(kind, url, repo_dir)
      @calls << { kind: kind, url: url, repo_dir: repo_dir }
      @data.fetch(kind)
    end
  end

  setup do
    @review = reviews(:pr_review)
    FileUtils.rm_rf(@review.artifacts_dir)
  end

  teardown { FileUtils.rm_rf(@review.artifacts_dir) }

  test "fetch! zapisuje artefakt obok result.json i zwraca jego treść" do
    client = FakeClient.new(files: [ { "filename" => "app/x.rb", "patch" => "@@ -1 +1 @@\n-a\n+b" } ],
                            review_comments: [ { "id" => 1, "path" => "app/x.rb", "line" => 1 } ],
                            issue_comments: [ { "id" => 2, "body" => "cześć" } ])

    snapshot = PrSnapshot.fetch!(@review, client: client)

    assert_equal "app/x.rb", snapshot.files.sole["filename"]
    assert_equal 1, snapshot.review_comments.sole["id"]
    assert_equal "cześć", snapshot.issue_comments.sole["body"]
    assert_in_delta Time.current, snapshot.fetched_at, 5
    assert_path_exists @review.artifacts_dir.join("pr_snapshot.json")
  end

  test "fetch! pyta o dane w katalogu pracy review" do
    client = FakeClient.new
    PrSnapshot.fetch!(@review, client: client)

    assert_equal %i[files review_comments issue_comments], client.calls.map { |c| c[:kind] }
    assert_equal [ @review.workdir ], client.calls.map { |c| c[:repo_dir] }.uniq
    assert_equal [ @review.pr_url ], client.calls.map { |c| c[:url] }.uniq
  end

  test "load czyta zapisany artefakt" do
    PrSnapshot.fetch!(@review, client: FakeClient.new(issue_comments: [ { "id" => 9 } ]))

    assert_equal 9, PrSnapshot.load(@review).issue_comments.sole["id"]
  end

  test "load bez artefaktu daje nil" do
    assert_nil PrSnapshot.load(@review)
  end

  # Przerwany zapis (ubity worker, brak miejsca) nie może wywracać strony —
  # brak artefaktu i artefakt nie do odczytania znaczą to samo: pobierz od nowa.
  test "load uszkodzonego artefaktu daje nil zamiast wyjątku" do
    FileUtils.mkdir_p(@review.artifacts_dir)
    @review.artifacts_dir.join("pr_snapshot.json").write("{ucięty")

    assert_nil PrSnapshot.load(@review)
  end

  test "stęchły, gdy na PR-ze coś się działo po pobraniu" do
    PrSnapshot.fetch!(@review, client: FakeClient.new)
    snapshot = PrSnapshot.load(@review)

    @review.update!(pr_activity_at: 1.hour.from_now)
    assert snapshot.stale?(@review)

    @review.update!(pr_activity_at: 1.hour.ago)
    assert_not snapshot.stale?(@review)
  end

  test "bez znanej aktywności na PR-ze snapshot nie jest stęchły" do
    PrSnapshot.fetch!(@review, client: FakeClient.new)
    @review.update!(pr_activity_at: nil)

    assert_not PrSnapshot.load(@review).stale?(@review)
  end

  test "fetch! nadpisuje poprzedni artefakt" do
    PrSnapshot.fetch!(@review, client: FakeClient.new(issue_comments: [ { "id" => 1 } ]))
    PrSnapshot.fetch!(@review, client: FakeClient.new(issue_comments: [ { "id" => 2 } ]))

    assert_equal 2, PrSnapshot.load(@review).issue_comments.sole["id"]
  end
end
