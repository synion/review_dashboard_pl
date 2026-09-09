# Ocenia świeżą sesją (bez --resume), czy PR rozwiązuje zgłoszone zadanie: premisa
# z dowodem, status każdego AC, pułapki i wymogu procesu. Werdykt liczy importer.
# Cykl poboczny: nie rusza statusu review ani znalezisk z review, tylko dokłada
# własne (source task_fit). Kolejkowany po każdym review i followupie oraz z przycisku.
class TaskFitJob < ApplicationJob
  queue_as :default

  def perform(review, session_factory: default_session_factory, github: GithubClient.new)
    return unless review.task_fit_possible?

    review.update!(task_fit_status: "running")
    run = review.claude_runs.create!(kind: "task_fit", claude_config: review.effective_claude_config)
    discussion = PrDiscussion.for(review, client: github)
    session_factory.call(run).call(PromptBuilder.task_fit(review, discussion: discussion))
    TaskFitImporter.call(review)
  rescue StandardError => e
    # Poprzedni werdykt zostaje (stary wynik jest lepszy niż żaden), status mówi,
    # że to nie jest aktualne; powód błędu panel czyta z runa (task_fit_error).
    Rails.logger.warn("TaskFitJob review #{review.id}: #{e.message}")
    review.update!(task_fit_status: "failed") if Review.exists?(review.id)
  end
end
