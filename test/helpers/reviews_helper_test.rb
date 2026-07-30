require "test_helper"

class ReviewsHelperTest < ActionView::TestCase
  include ReviewsHelper



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
end
