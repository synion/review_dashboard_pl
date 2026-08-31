require "test_helper"

class AutoReviewTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @project = projects(:webapp)
    @item = inbox_items(:requested)
  end

  # --- nowe prośby o review -------------------------------------------------

  test "wyłączony automat nie zakłada niczego" do
    assert_no_difference -> { Review.count } do
      assert_equal 0, AutoReview.create_for_requested(@project)
    end
  end

  test "włączony automat zakłada review na prośbę z kolejki i kolejkuje describe" do
    @project.update!(auto_review_requested: true)

    assert_difference -> { Review.count }, 1 do
      assert_equal 1, AutoReview.create_for_requested(@project)
    end

    review = Review.order(:id).last
    assert_equal @item.url, review.pr_url
    assert review.autostart?
    assert_equal @project.default_claude_config, review.claude_config
    assert_enqueued_with job: DescribeReviewJob, args: [ review ]
  end

  # „commented" znaczy, że review na tym PR-ze już było — jego ciągiem dalszym jest
  # followup, a nie drugi komplet znalezisk od zera.
  test "pozycja commented nie zakłada nowego review" do
    @project.update!(auto_review_requested: true)
    @item.destroy!

    assert_no_difference -> { Review.count } do
      assert_equal 0, AutoReview.create_for_requested(@project)
    end
  end

  test "PR z istniejącym review jest pomijany" do
    @project.update!(auto_review_requested: true)
    @project.reviews.create!(pr_url: @item.url, pr_number: @item.pr_number, status: "reviewed")

    assert_no_difference -> { Review.count } do
      assert_equal 0, AutoReview.create_for_requested(@project)
    end
  end

  test "zarchiwizowany projekt nie zakłada review" do
    @project.update!(auto_review_requested: true, archived_at: Time.current)

    assert_no_difference -> { Review.count } do
      assert_equal 0, AutoReview.create_for_requested(@project)
    end
  end

  # Jeden niezapisywalny PR nie może zablokować pozostałych pozycji kolejki.
  test "odrzucony przez walidację PR nie przerywa reszty" do
    @project.update!(auto_review_requested: true)
    @project.inbox_items.create!(pr_number: 9003, url: "https://github.com/inne/repo/pull/9003",
                                 reason: "requested", author: "ktos")

    assert_difference -> { Review.count }, 1 do
      assert_equal 1, AutoReview.create_for_requested(@project)
    end
  end

  # --- samoczynny start po describe ----------------------------------------

  test "review z autostart rusza po osiągnięciu ready" do
    review = @project.reviews.create!(pr_url: "https://github.com/acme/webapp/pull/7", autostart: true, status: "ready")

    assert AutoReview.start_if_autostart(review)
    assert_equal "reviewing", review.reload.status
    assert_equal AutoReview::AUTO_AREAS, review.selected_areas
    assert_not_includes review.selected_areas, "qa_playwright"
    assert review.inline_comments?
    assert_enqueued_with job: RunReviewJob, args: [ review ]
  end

  test "review bez flagi autostart nie rusza sam" do
    review = @project.reviews.create!(pr_url: "https://github.com/acme/webapp/pull/8", status: "ready")

    assert_no_enqueued_jobs only: RunReviewJob do
      assert_not AutoReview.start_if_autostart(review)
    end
    assert_equal "ready", review.reload.status
  end

  # Guard jak w ReviewsController#start: druga sesja nadpisałaby wynik pierwszej.
  test "autostart nie rusza review, które już nie jest ready" do
    review = @project.reviews.create!(pr_url: "https://github.com/acme/webapp/pull/9", autostart: true,
                                      status: "reviewed")

    assert_no_enqueued_jobs only: RunReviewJob do
      assert_not AutoReview.start_if_autostart(review)
    end
  end

  # --- PR wrócony po poprawkach --------------------------------------------

  test "wyłączony automat nie odpala followupu" do
    review = reviews(:pr_review)
    review.update!(status: "waiting_review")

    assert_no_enqueued_jobs only: FollowupReviewJob do
      assert_not AutoReview.followup_for_returned(review)
    end
    assert_equal "waiting_review", review.reload.status
  end

  test "włączony automat odpala followup i od razu przestawia status" do
    @project.update!(auto_review_returned: true)
    review = reviews(:pr_review)
    review.update!(status: "waiting_review")

    assert AutoReview.followup_for_returned(review)
    assert_equal "reviewing", review.reload.status
    assert_enqueued_with job: FollowupReviewJob, args: [ review, AutoReview::RETURNED_MESSAGE ]
  end

  test "followup nie rusza review w statusie, z którego się nie da" do
    @project.update!(auto_review_returned: true)
    review = reviews(:pr_review)
    review.update!(status: "merged")

    assert_no_enqueued_jobs only: FollowupReviewJob do
      assert_not AutoReview.followup_for_returned(review)
    end
  end
end
