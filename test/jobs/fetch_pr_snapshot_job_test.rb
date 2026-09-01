require "test_helper"

class FetchPrSnapshotJobTest < ActiveJob::TestCase
  class FakeClient
    def pr_files(_url, repo_dir:) = [ { "filename" => "app/x.rb" } ]
    def pr_review_comments(_url, repo_dir:) = []
    def pr_issue_comments(_url, repo_dir:) = []
    def pr_author(_url, repo_dir:) = "autor"
    def viewer_login(repo_dir:) = "ja"
  end

  class FailingClient < FakeClient
    def pr_files(_url, repo_dir:) = raise(GithubClient::Error, "gh api: not found")
  end

  # Testy jadą na :null_store, w którym marker „job już leci" i komunikat błędu
  # nie mają gdzie usiąść — na czas tych testów podstawiamy pamięć.
  setup do
    @review = reviews(:pr_review)
    FileUtils.rm_rf(@review.artifacts_dir)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
    FileUtils.rm_rf(@review.artifacts_dir)
  end

  test "pobiera snapshot i czyści marker" do
    FetchPrSnapshotJob.perform_now(@review, client: FakeClient.new)

    assert_equal "app/x.rb", PrSnapshot.load(@review).files.sole["filename"]
    assert_nil Rails.cache.read(FetchPrSnapshotJob.marker_key(@review))
  end

  # Padnięte `gh` (PR usunięty, brak sieci) nie może wywalać strony — komunikat
  # ląduje w cache, żeby widok mógł go pokazać obok przycisku „spróbuj ponownie".
  test "błąd gh zapisuje się jako komunikat, nie wyjątek" do
    FetchPrSnapshotJob.perform_now(@review, client: FailingClient.new)

    assert_includes Rails.cache.read(FetchPrSnapshotJob.error_key(@review)), "not found"
    assert_nil PrSnapshot.load(@review)
  end

  test "udane pobranie kasuje poprzedni błąd" do
    Rails.cache.write(FetchPrSnapshotJob.error_key(@review), "stary błąd")

    FetchPrSnapshotJob.perform_now(@review, client: FakeClient.new)

    assert_nil Rails.cache.read(FetchPrSnapshotJob.error_key(@review))
  end

  test "review bez PR-a nie woła GitHuba" do
    review = reviews(:task_only)

    FetchPrSnapshotJob.perform_now(review, client: FailingClient.new)

    assert_nil PrSnapshot.load(review)
    assert_nil Rails.cache.read(FetchPrSnapshotJob.error_key(review))
  end

  test "enqueue trzyma jeden job w locie na review" do
    assert_enqueued_jobs 1 do
      2.times { FetchPrSnapshotJob.enqueue(@review) }
    end
  end

  test "enqueue z force pomija marker" do
    FetchPrSnapshotJob.enqueue(@review)

    assert_enqueued_jobs 1 do
      FetchPrSnapshotJob.enqueue(@review, force: true)
    end
  end
end
