require "test_helper"

class DescribeReviewJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FakeGithub
    def initialize(body: nil) = @body = body

    def pr_info(_url, repo_dir:) = { "number" => 1234, "title" => "Fix VAT",
                                     "headRefName" => "sl-fix-vat", "body" => @body }
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

  # PR wklejony ręcznie też ma dostać link do zadania — bez niego cały poboczny cykl
  # (opis zadania, komentarz po decyzji) zostaje wyłączony.
  test "should take the task link from the PR description when the form left it empty" do
    projects(:webapp).update!(task_url_prefix: "https://tracker.example.com/organize/tasks/")
    review = reviews(:pr_review)
    github = FakeGithub.new(body: "Zadanie [#32586](https://tracker.example.com/organize/tasks/32586)")

    DescribeReviewJob.perform_now(review, github: github, worktrees: FakeWorktrees.new,
                                          session_factory: ->(_run) { FakeSession.new("OPIS") })

    assert_equal "https://tracker.example.com/organize/tasks/32586", review.reload.task_url
  end

  test "should never overwrite a task link that came from the form" do
    projects(:webapp).update!(task_url_prefix: "https://tracker.example.com/organize/tasks/")
    review = reviews(:pr_review)
    review.update!(task_url: "https://tracker.example.com/organize/tasks/1")
    github = FakeGithub.new(body: "Zadanie https://tracker.example.com/organize/tasks/99")

    DescribeReviewJob.perform_now(review, github: github, worktrees: FakeWorktrees.new,
                                          session_factory: ->(_run) { FakeSession.new("OPIS") })

    assert_equal "https://tracker.example.com/organize/tasks/1", review.reload.task_url
  end

  # Review założone przez automat ma przejść z describe wprost w review — bez tego
  # przełącznik „auto: nowe prośby" zostawiałby stos gotowych review do odklikania.
  test "review z flagą autostart rusza od razu po opisie" do
    review = reviews(:pr_review)
    review.update!(autostart: true)

    assert_enqueued_with job: RunReviewJob, args: [ review ] do
      DescribeReviewJob.perform_now(review, github: FakeGithub.new, worktrees: FakeWorktrees.new,
                                            session_factory: ->(_run) { FakeSession.new("OPIS") })
    end
    assert_equal "reviewing", review.reload.status
  end

  test "review bez flagi zatrzymuje się na ready" do
    review = reviews(:pr_review)

    assert_no_enqueued_jobs only: RunReviewJob do
      DescribeReviewJob.perform_now(review, github: FakeGithub.new, worktrees: FakeWorktrees.new,
                                            session_factory: ->(_run) { FakeSession.new("OPIS") })
    end
    assert_equal "ready", review.reload.status
  end
end
