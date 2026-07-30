require "test_helper"

class TaskCommentsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @review = reviews(:task_only)
    @review.update!(status: "decided", decision: "approve", task_comment_status: "failed")
  end

  test "ponów: kolejkuje job i ustawia queued" do
    assert_enqueued_with(job: CommentTaskJob, args: [ @review ]) do
      post review_task_comment_path(@review)
    end
    assert_equal "queued", @review.reload.task_comment_status
    assert_redirected_to review_path(@review)
  end

  test "guard na podwójny klik: queued/running nie kolejkuje drugiego joba" do
    %w[queued running].each do |status|
      @review.update!(task_comment_status: status)
      assert_no_enqueued_jobs only: CommentTaskJob do
        post review_task_comment_path(@review)
      end
      assert_equal status, @review.reload.task_comment_status
    end
  end

  test "bez task_url nie ma czego ponawiać" do
    review = reviews(:pr_review)
    review.update!(status: "decided", task_comment_status: "failed")
    assert_no_enqueued_jobs only: CommentTaskJob do
      post review_task_comment_path(review)
    end
    assert_equal "Ten review nie ma linku do zadania", flash[:alert]
  end
end
