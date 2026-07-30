class FollowupReviewJob < ApplicationJob
  queue_as :default

  def perform(review, message, session_factory: default_session_factory)
    review.update!(status: "reviewing")
    config = review.effective_claude_config
    # Po przełączeniu konta sesja może leżeć w drugim configu — `--resume` zwróciłby
    # wtedy „No conversation found". Bierzemy najnowszą, której plik faktycznie tu jest;
    # gdy żadnej nie ma, świeża sesja dostaje kontekst z promptu.
    base = review.resumable_session_run(config)

    run = review.claude_runs.create!(kind: "followup", claude_config: config,
                                     user_message: message, resume_session_id: base&.session_id)
    session_factory.call(run).call(PromptBuilder.followup(review, message, resumed: base.present?))
    ReviewResultImporter.call(review)
    review.update!(status: "reviewed")
  rescue StandardError => e
    # Review mógł zostać usunięty z dashboardu w trakcie działania joba.
    review.fail!(e.message) if Review.exists?(review.id)
  end
end
