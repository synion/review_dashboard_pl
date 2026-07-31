require "test_helper"

class PrReviewersTest < ActiveSupport::TestCase
  class FakeGithub
    def initialize(reviews: [], error: nil, viewer: "me")
      @reviews, @error, @viewer = reviews, error, viewer
    end

    def viewer_login(repo_dir:) = @viewer

    def pr_reviews(pr_url, repo_dir:)
      raise GithubClient::Error, @error if @error
      @reviews
    end
  end

  setup do
    @review = reviews(:pr_review)
  end

  test "zapisuje na review ostatni stan per login, bez własnego konta" do
    fake = FakeGithub.new(reviews: [
      { "author" => { "login" => "anna" }, "state" => "CHANGES_REQUESTED", "submittedAt" => "2026-07-30T10:00:00Z" },
      { "author" => { "login" => "anna" }, "state" => "APPROVED", "submittedAt" => "2026-07-31T10:00:00Z" },
      { "author" => { "login" => "me" }, "state" => "APPROVED", "submittedAt" => "2026-07-31T11:00:00Z" }
    ])

    PrReviewers.refresh!(@review, client: fake)

    @review.reload
    assert_equal [ { "login" => "anna", "state" => "APPROVED" } ], @review.pr_reviewers_list
    assert @review.pr_reviewers_checked_at.present?
    assert_not @review.pr_reviewers_stale?
  end

  test "po błędzie gh zostaje ostatni znany stan" do
    @review.update!(pr_reviewers: [ { "login" => "anna", "state" => "APPROVED" } ],
                    pr_reviewers_checked_at: 1.day.ago)

    PrReviewers.refresh!(@review, client: FakeGithub.new(error: "gh padł"))

    assert_equal [ { "login" => "anna", "state" => "APPROVED" } ], @review.reload.pr_reviewers_list
  end

  test "review bez pr_url nie pyta gh i niczego nie zapisuje" do
    review = reviews(:task_only)
    PrReviewers.refresh!(review, client: FakeGithub.new(error: "nie wolno"))

    assert_nil review.reload.pr_reviewers_checked_at
  end
end
