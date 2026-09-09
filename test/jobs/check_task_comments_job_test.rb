require "test_helper"

class CheckTaskCommentsJobTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:task_only)
    @review.project.update!(task_url_prefix: "https://tasks.example.com/", intum_api_token: "t")
    @review.update!(task_comments_seen: 5, task_comments_latest: 5)
  end

  def fake(count)
    Object.new.tap { |f| f.define_singleton_method(:task) { |_id| { "id" => 1, "comments_count" => count } } }
  end

  test "zapisuje bieżącą liczbę komentarzy i stempel" do
    IntumClient.stub(:new, fake(8)) { CheckTaskCommentsJob.perform_now(@review) }
    @review.reload
    assert_equal 8, @review.task_comments_latest
    assert_not_nil @review.task_comments_checked_at
    assert @review.task_comments_stale?
  end

  test "padnięty tracker zostawia ostatnią znaną liczbę, ale stempluje sprawdzenie" do
    broken = Object.new
    def broken.task(_id) = raise(IntumClient::Error, "502")
    IntumClient.stub(:new, broken) { CheckTaskCommentsJob.perform_now(@review) }
    @review.reload
    assert_equal 5, @review.task_comments_latest
    assert_not_nil @review.task_comments_checked_at
  end
end
