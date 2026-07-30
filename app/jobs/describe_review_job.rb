class DescribeReviewJob < ApplicationJob
  queue_as :default

  def perform(review, github: GithubClient.new, worktrees: nil, session_factory: default_session_factory)
    worktrees ||= WorktreeManager.new(review.project)
    review.update!(status: "describing")

    if review.pr_url.present?
      info = github.pr_info(review.pr_url, repo_dir: review.project.repo_path)
      review.update!(pr_number: info["number"], pr_title: info["title"], branch: info["headRefName"])
    end

    if review.branch.present?
      path = worktrees.ensure_for_branch(review.branch)
      review.update!(worktree_path: path)
      worktrees.checkout_pr(path, review.pr_url) if review.pr_url.present?
    else
      review.update!(worktree_path: review.project.repo_path)
    end

    run = review.claude_runs.create!(kind: "describe", claude_config: review.effective_claude_config)
    description = session_factory.call(run).call(PromptBuilder.describe(review))
    review.update!(description: description, status: "ready")
  rescue StandardError => e
    # Review mógł zostać usunięty z dashboardu w trakcie działania joba.
    review.fail!(e.message) if Review.exists?(review.id)
  end
end
