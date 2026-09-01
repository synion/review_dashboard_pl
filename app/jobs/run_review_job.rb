class RunReviewJob < ApplicationJob
  queue_as :default
  # Jedno ponowienie po zwisie. Więcej nie ma sensu: jeśli sesja zawisła dwa razy
  # z rzędu, to problem jest w zadaniu albo w środowisku, a nie w chwilowym zacięciu.
  MAX_ATTEMPTS = 2

  def perform(review, session_factory: default_session_factory, github: GithubClient.new)
    review.update!(status: "reviewing")
    # Rozmowa z PR-a jedzie do promptu: na PR-ze potrafią już wisieć cudze uwagi
    # i odpowiedzi autora, a review, które ich nie widzi, zgłasza rzecz świeżo
    # wyjaśnioną. Pobranie jest odporne na padnięty `gh` (patrz PrSnapshot.refresh).
    discussion = PrDiscussion.for(review, client: github)
    attempt = 0
    begin
      attempt += 1
      run = review.claude_runs.create!(kind: "review", claude_config: review.effective_claude_config)
      session_factory.call(run).call(PromptBuilder.review(review, discussion: discussion))
    rescue ClaudeSessionRunner::Stalled
      # Timeoutu całkowitego nie ponawiamy — praca się od tego nie skróci.
      raise if attempt >= MAX_ATTEMPTS

      Rails.logger.warn("Review #{review.id}: sesja zawisła, ponawiam (próba #{attempt + 1}/#{MAX_ATTEMPTS})")
      retry
    end
    return unless review.still_reviewing?

    ReviewResultImporter.call(review)
    review.update!(status: "reviewed")
  rescue StandardError => e
    review.fail!(e.message) if review.still_reviewing?
  end
end
