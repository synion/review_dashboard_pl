require "test_helper"

class DescribeReviewJobTest < ActiveSupport::TestCase
  class FakeGithub
    def pr_info(_url, repo_dir:) = { "number" => 1234, "title" => "Fix VAT", "headRefName" => "sl-fix-vat" }
  end

  class FakeWorktrees
    def ensure_for_branch(_branch) = "/tmp/wt-sl-fix-vat"
    def checkout_pr(_path, _url) = nil
  end

  class FakeSession
    def initialize(text) = @text = text
    def call(_prompt) = @text
  end

  test "PR: uzupełnia metadane, worktree i opis, status ready" do
    review = reviews(:pr_review)
    DescribeReviewJob.perform_now(review, github: FakeGithub.new, worktrees: FakeWorktrees.new, session_factory: ->(_run) { FakeSession.new("OPIS ZADANIA") })
    review.reload
    assert_equal(
      { status: "ready", description: "OPIS ZADANIA", pr_number: 1234, pr_title: "Fix VAT",
        branch: "sl-fix-vat", worktree_path: "/tmp/wt-sl-fix-vat" },
      { status: review.status, description: review.description, pr_number: review.pr_number,
        pr_title: review.pr_title, branch: review.branch, worktree_path: review.worktree_path }
    )
    assert_equal [ { kind: "describe", status: "pending" } ],
                 review.claude_runs.map { |r| { kind: r.kind, status: r.status } }
  end

  test "zadanie bez brancha: worktree = repo projektu" do
    review = reviews(:task_only)
    DescribeReviewJob.perform_now(review, github: FakeGithub.new, worktrees: FakeWorktrees.new, session_factory: ->(_run) { FakeSession.new("OPIS") })
    review.reload
    assert_equal({ status: "ready", worktree_path: "/Users/dev/projects/webapp", branch: nil },
                 { status: review.status, worktree_path: review.worktree_path, branch: review.branch })
  end

  test "zadanie z branchem: tworzy worktree jak dla PR" do
    review = reviews(:task_only)
    review.update!(branch: "sl-fix-vat")
    DescribeReviewJob.perform_now(review, github: FakeGithub.new, worktrees: FakeWorktrees.new, session_factory: ->(_run) { FakeSession.new("OPIS") })
    assert_equal "/tmp/wt-sl-fix-vat", review.reload.worktree_path
  end

  test "błąd serwisu ustawia failed z komunikatem" do
    review = reviews(:pr_review)
    failing = Object.new.tap { |o| o.define_singleton_method(:pr_info) { |*_args, **_kw| raise GithubClient::Error, "no pull requests found" } }
    DescribeReviewJob.perform_now(review, github: failing, worktrees: FakeWorktrees.new, session_factory: ->(_run) { FakeSession.new("x") })
    review.reload
    assert_equal "failed", review.status
    assert_includes review.error_message, "no pull requests found"
  end

  test "sesja describe używa configu wybranego na review" do
    review = reviews(:pr_review)
    review.update!(claude_config: "/Users/dev/.claude-b")
    DescribeReviewJob.perform_now(review, github: FakeGithub.new, worktrees: FakeWorktrees.new, session_factory: ->(_run) { FakeSession.new("OPIS") })
    assert_equal [ "/Users/dev/.claude-b" ], review.claude_runs.map(&:claude_config)
  end
end
