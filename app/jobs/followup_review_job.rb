class FollowupReviewJob < ApplicationJob
  queue_as :default

  def perform(review, message, session_factory: default_session_factory, github: GithubClient.new)
    review.update!(status: "reviewing")
    config = review.effective_claude_config
    # Po przełączeniu konta sesja może leżeć w drugim configu — `--resume` zwróciłby
    # wtedy „No conversation found". Bierzemy najnowszą, której plik faktycznie tu jest;
    # gdy żadnej nie ma, świeża sesja dostaje kontekst z promptu.
    base = review.resumable_session_run(config)

    # Ponowna ocena tego samego PR-a musi znać odpowiedzi autora na wysłane pinezki —
    # bez nich followup zgłasza po raz drugi uwagę, którą autor już na PR-ze uzasadnił.
    discussion = PrDiscussion.for(review, client: github)

    run = review.claude_runs.create!(kind: "followup", claude_config: config,
                                     user_message: message, resume_session_id: base&.session_id)
    session_factory.call(run).call(
      PromptBuilder.followup(review, message, resumed: base.present?, discussion: discussion)
    )
    return unless review.still_reviewing?

    ReviewResultImporter.call(review)
    review.mark_reviewed!
  rescue StandardError => e
    review.fail!(e.message) if review.still_reviewing?
  end
end
