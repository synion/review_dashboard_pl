class RunReviewJob < ApplicationJob
  queue_as :default
  # Jedno ponowienie po zwisie. Więcej nie ma sensu: jeśli sesja zawisła dwa razy
  # z rzędu, to problem jest w zadaniu albo w środowisku, a nie w chwilowym zacięciu.
  MAX_ATTEMPTS = 2

  def perform(review, session_factory: default_session_factory)
    review.update!(status: "reviewing")
    attempt = 0
    begin
      attempt += 1
      run = review.claude_runs.create!(kind: "review", claude_config: review.effective_claude_config)
      session_factory.call(run).call(PromptBuilder.review(review))
    rescue ClaudeSessionRunner::Stalled
      # Timeoutu całkowitego nie ponawiamy — praca się od tego nie skróci.
      raise if attempt >= MAX_ATTEMPTS

      Rails.logger.warn("Review #{review.id}: sesja zawisła, ponawiam (próba #{attempt + 1}/#{MAX_ATTEMPTS})")
      retry
    end
    ReviewResultImporter.call(review)
    review.update!(status: "reviewed")
  rescue StandardError => e
    # Review mógł zostać usunięty z dashboardu w trakcie działania joba.
    review.fail!(e.message) if Review.exists?(review.id)
  end
end
