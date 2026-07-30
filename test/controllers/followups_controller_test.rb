require "test_helper"

class FollowupsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "reviewed", summary: "OK")
  end

  test "create kolejkuje FollowupReviewJob z wiadomością" do
    assert_enqueued_with(job: FollowupReviewJob, args: [ @review, "nie zgadzam się z X" ]) do
      post review_followup_path(@review), params: { message: "nie zgadzam się z X" }
    end
    assert_redirected_to review_path(@review)
  end

  test "create od razu przestawia review w reviewing, zanim job ruszy" do
    post review_followup_path(@review), params: { message: "nie zgadzam się z X" }
    assert_equal "reviewing", @review.reload.status
  end

  test "create działa też ze statusu waiting_review" do
    @review.update!(status: "waiting_review")
    assert_enqueued_with(job: FollowupReviewJob) do
      post review_followup_path(@review), params: { message: "sprawdź poprawki" }
    end
    assert_equal "reviewing", @review.reload.status
  end

  test "create działa też ze statusu decided — PR, o który GitHub nigdy nie poprosi" do
    @review.update!(status: "decided", decision: "approve", decided_at: Time.current)
    assert_enqueued_with(job: FollowupReviewJob) do
      post review_followup_path(@review), params: { message: "sprawdź moje poprawki" }
    end
    assert_equal "reviewing", @review.reload.status
  end

  test "w statusie końcowym followup odrzucony — nie ma już czego sprawdzać" do
    @review.update!(status: "merged")
    assert_no_enqueued_jobs(only: FollowupReviewJob) do
      post review_followup_path(@review), params: { message: "sprawdź poprawki" }
    end
    assert_equal "merged", @review.reload.status
  end

  test "poza statusem reviewed odrzuca bez kolejkowania" do
    @review.update!(status: "reviewing")
    assert_no_enqueued_jobs(only: FollowupReviewJob) do
      post review_followup_path(@review), params: { message: "x" }
    end
    assert_equal "Dyskusja możliwa tylko na zakończonym review (status: reviewing)", flash[:alert]
  end

  test "pusta wiadomość odrzucana" do
    assert_no_enqueued_jobs(only: FollowupReviewJob) do
      post review_followup_path(@review), params: { message: "" }
    end
    assert_equal "Napisz, z czym się nie zgadzasz", flash[:alert]
  end
end
