require "test_helper"

class CommentTaskJobTest < ActiveSupport::TestCase
  class FakeSession
    def initialize(text) = @text = text
    def call(_prompt) = @text
  end

  setup do
    @review = reviews(:task_only)
    @review.update!(decision: "approve", decision_body: "LGTM")
  end

  def run_with(text)
    CommentTaskJob.perform_now(@review, session_factory: ->(_run) { FakeSession.new(text) })
    @review.reload
  end

  test "sukces: zapisuje treść komentarza i status ready" do
    run_with("Review skończone: zatwierdzone bez uwag.")
    assert_equal "ready", @review.task_comment_status
    assert_equal "Review skończone: zatwierdzone bez uwag.", @review.task_comment
    assert_equal [ "comment_task" ], @review.claude_runs.map(&:kind)
  end

  test "ERROR: status failed, powód czytelny z task_comment_error, treść nietknięta" do
    @review.update!(task_comment: "POPRZEDNI KOMENTARZ")
    run_with("ERROR: wygasła sesja trackera")
    assert_equal "failed", @review.task_comment_status
    assert_equal "wygasła sesja trackera", @review.task_comment_error
    assert_equal "POPRZEDNI KOMENTARZ", @review.task_comment, "porażka nie może zamazać śladu dodanego komentarza"
  end

  test "wyjątek sesji: failed, treść i status review nietknięte" do
    @review.update!(task_comment: "POPRZEDNI KOMENTARZ")
    failing = ->(_run) { raise ClaudeSessionRunner::Failed, "sesja padła" }
    CommentTaskJob.perform_now(@review, session_factory: failing)
    @review.reload
    assert_equal "failed", @review.task_comment_status
    assert_equal "POPRZEDNI KOMENTARZ", @review.task_comment
    assert_equal "created", @review.status, "porażka komentarza nie dotyka cyklu review"
  end
end
