require "test_helper"

class ReviewsHelperTest < ActionView::TestCase
  include ReviewsHelper

  test "should name the next move for every status a review can sit in" do
    waiting = Review::ATTENTION_STATUSES + Review::IN_PROGRESS_STATUSES
    waiting.each do |status|
      review = reviews(:pr_review)
      review.status = status
      assert review_next_step(review).present?, "brak następnego kroku dla #{status}"
    end
  end

  # Stany końcowe nie mają następnego ruchu — kafel kolejki ich nie pokazuje,
  # ale helper nie może na nich wybuchać (np. review zmergowane w trakcie renderu).
  test "should return nil as the next move for finished reviews" do
    review = reviews(:pr_review)
    review.status = "merged"
    assert_nil review_next_step(review)
  end

  test "should describe waiting time in whole Polish units" do
    review = reviews(:pr_review)

    review.updated_at = 30.seconds.ago
    assert_equal "chwilę", review_waiting_for(review)
    review.updated_at = 5.minutes.ago
    assert_equal "5 min", review_waiting_for(review)
    review.updated_at = 3.hours.ago
    assert_equal "3 godz.", review_waiting_for(review)
    review.updated_at = 1.day.ago - 1.hour
    assert_equal "1 dzień", review_waiting_for(review)
    review.updated_at = 9.days.ago
    assert_equal "9 dni", review_waiting_for(review)
  end

  test "should count findings with Polish plural forms and flag blockers" do
    review = reviews(:pr_review)
    assert_nil review_findings_summary(review), "bez znalezisk nie ma czego pokazywać"

    review.findings.create!(priority: "minor", title: "a", body: "x")
    assert_equal "1 znalezisko", review_findings_summary(review.reload)

    review.findings.create!(priority: "critical", title: "b", body: "x")
    assert_equal "2 znaleziska · 1 krytyczne", review_findings_summary(review.reload)

    3.times { |i| review.findings.create!(priority: "minor", title: "c#{i}", body: "x") }
    assert_equal "5 znalezisk · 1 krytyczne", review_findings_summary(review.reload)
  end

  test "should keep the teens in the genitive plural form" do
    assert_equal "znalezisk", findings_noun(13)
    assert_equal "znaleziska", findings_noun(23)
    assert_equal "znalezisk", findings_noun(25)
  end
end
