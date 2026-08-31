require "test_helper"

class PrDiffsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  PATCH = "@@ -10,3 +10,4 @@ class Invoice\n   def total\n-    items.sum(&:price)\n" \
          "+    return 0 if items.empty?\n+    items.sum(&:price)\n"

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

  def write_snapshot(review_comments: [], issue_comments: [], files: nil)
    files ||= [ { "filename" => "app/models/invoice.rb", "status" => "modified",
                  "additions" => 2, "deletions" => 1, "patch" => PATCH } ]
    FileUtils.mkdir_p(@review.artifacts_dir)
    PrSnapshot.path_for(@review).write(JSON.generate(
      "fetched_at" => Time.current.iso8601, "files" => files,
      "review_comments" => review_comments, "issue_comments" => issue_comments))
  end

  test "bez artefaktu pokazuje placeholder i zleca pobranie" do
    assert_enqueued_with(job: FetchPrSnapshotJob) do
      get diff_review_path(@review)
    end

    assert_response :success
    assert_select "#review_#{@review.id}_diff"
    assert_select "body", text: /Pobieram zmiany z GitHuba/
  end

  test "z artefaktem renderuje linie diffu i nie pyta GitHuba" do
    write_snapshot

    assert_no_enqueued_jobs(only: FetchPrSnapshotJob) do
      get diff_review_path(@review)
    end

    assert_response :success
    assert_select "td.diff-code", text: /return 0 if items.empty\?/
    assert_select ".diff-file-head", text: /app\/models\/invoice\.rb/
  end

  test "komentarz z GitHuba ląduje przy swojej linii" do
    write_snapshot(review_comments: [ { "id" => 1, "path" => "app/models/invoice.rb", "line" => 12,
                                        "side" => "RIGHT", "position" => 3, "subject_type" => "line",
                                        "user" => "kolega", "body" => "a co jak nil?",
                                        "created_at" => "2026-08-27T10:00:00Z" } ])

    get diff_review_path(@review)

    assert_select "tr.diff-comment-row .diff-comment-body", text: /a co jak nil\?/
  end

  test "znalezisko Claude'a ląduje przy swojej linii" do
    @review.findings.create!(priority: "critical", title: "Brak obsługi nil",
                             body: "treść", file_location: "app/models/invoice.rb:12")
    write_snapshot

    get diff_review_path(@review)

    assert_select "tr.diff-finding-row", text: /Brak obsługi nil/
  end

  test "stęchły artefakt zleca odświeżenie, ale pokazuje to, co jest" do
    write_snapshot
    @review.update!(pr_activity_at: 1.hour.from_now)

    assert_enqueued_with(job: FetchPrSnapshotJob) do
      get diff_review_path(@review)
    end

    assert_select "td.diff-code", text: /return 0 if items.empty\?/
  end

  test "widok split zapamiętuje się w ciasteczku" do
    write_snapshot

    get diff_review_path(@review, view: "split")
    assert_select "table.diff-split"

    # Wejście bez parametru: wybór ma przeżyć w ciasteczku.
    get diff_review_path(@review)
    assert_select "table.diff-split"
  end

  test "błąd gh pokazuje się zamiast diffu" do
    Rails.cache.write(FetchPrSnapshotJob.error_key(@review), "gh api: not found")

    get diff_review_path(@review)

    assert_select ".error-box", text: /not found/
  end

  test "odśwież zleca pobranie mimo markera i wraca na podstronę" do
    FetchPrSnapshotJob.enqueue(@review)

    assert_enqueued_with(job: FetchPrSnapshotJob) do
      post refresh_diff_review_path(@review)
    end

    assert_redirected_to diff_review_path(@review)
  end

  test "review bez PR-a nie ma czego pokazać" do
    get diff_review_path(reviews(:task_only))

    assert_redirected_to review_path(reviews(:task_only))
  end

  test "strona review linkuje do podglądu zmian" do
    get review_path(@review)

    assert_select "a[href=?]", diff_review_path(@review)
  end
end
