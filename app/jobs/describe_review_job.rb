class DescribeReviewJob < ApplicationJob
  queue_as :default

  def perform(review, github: GithubClient.new, worktrees: nil, session_factory: default_session_factory)
    worktrees ||= WorktreeManager.new(review.project)
    review.update!(status: "describing")

    if review.pr_url.present?
      info = github.pr_info(review.pr_url, repo_dir: review.project.repo_path)
      # task_url z opisu PR-a, gdy nie przyszedł z formularza: konwencja zespołu mówi,
      # że zadanie jest w opisie podlinkowane, a bez tego linku cały poboczny cykl
      # (opis zadania, komentarz po decyzji) zostaje wyłączony.
      task_url = review.task_url.presence ||
                 TaskLink.find(info["body"], prefix: review.project.task_url_prefix)
      review.update!(pr_number: info["number"], pr_title: info["title"],
                     branch: info["headRefName"], task_url: task_url)
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
