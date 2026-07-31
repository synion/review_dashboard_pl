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

  class FakeIntum
    Comment = Struct.new(:task_pk, :content, :responsible_id)

    def initialize(task_pk: 9876, error: nil)
      @task_pk, @error = task_pk, error
      @comments = []
    end

    attr_reader :comments

    def task(scoped_id)
      raise IntumClient::Error, @error if @error
      { "id" => @task_pk }
    end

    def post_comment(task_pk, content, responsible_id: nil)
      @comments << Comment.new(task_pk, content, responsible_id)
    end
  end

  def enable_intum!
    @review.project.update!(task_url_prefix: "https://tracker.example.com/organize/tasks/",
                            intum_api_token: "t")
    @review.update!(task_url: "https://tracker.example.com/organize/tasks/123")
  end

  test "z tokenem: treść od sesji, wysyłka przez API po PK z responsible" do
    enable_intum!
    @review.update!(task_comment_responsible_id: "55")
    fake = FakeIntum.new(task_pk: 9876)

    CommentTaskJob.perform_now(@review, session_factory: ->(_run) { FakeSession.new("Zatwierdzone.") }, intum: fake)

    assert_equal [ FakeIntum::Comment.new(9876, "Zatwierdzone.", "55") ], fake.comments
    assert_equal "ready", @review.reload.task_comment_status
    assert_equal "Zatwierdzone.", @review.task_comment
  end

  test "z tokenem bez wybranej osoby: komentarz bez responsible" do
    enable_intum!
    fake = FakeIntum.new

    CommentTaskJob.perform_now(@review, session_factory: ->(_run) { FakeSession.new("Zatwierdzone.") }, intum: fake)

    assert_nil fake.comments.sole.responsible_id
  end

  test "błąd API trackera: failed z powodem na runie, treść nie zamazana" do
    enable_intum!
    @review.update!(task_comment: "POPRZEDNI KOMENTARZ")
    fake = FakeIntum.new(error: "tracker odpowiedział 403")

    CommentTaskJob.perform_now(@review, session_factory: ->(_run) { FakeSession.new("Nowa treść.") }, intum: fake)

    @review.reload
    assert_equal "failed", @review.task_comment_status
    assert_includes @review.task_comment_error, "403"
    assert_equal "POPRZEDNI KOMENTARZ", @review.task_comment
  end

  test "ERROR od sesji z tokenem: nie próbuje wysyłać przez API" do
    enable_intum!
    fake = FakeIntum.new

    CommentTaskJob.perform_now(@review, session_factory: ->(_run) { FakeSession.new("ERROR: brak treści decyzji") }, intum: fake)

    assert_empty fake.comments
    assert_equal "failed", @review.reload.task_comment_status
  end
end
