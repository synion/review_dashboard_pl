require "test_helper"

class PlaywrightRunsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "create tworzy run i kolejkuje job" do
    review = reviews(:pr_review)
    review.update!(status: "reviewed", playwright_command: "npx playwright test x.spec.js", worktree_path: "/wt")
    assert_enqueued_with(job: PlaywrightRunJob) do
      post review_playwright_runs_path(review, mode: "headed")
    end
    assert_equal [ { mode: "headed", status: "running" } ], review.playwright_runs.map { |r| { mode: r.mode, status: r.status } }
    assert_redirected_to review_path(review)
  end
end
