# Ręczna kompakcja sesji review. `/compact` jest przechwytywane przez CLI jako komenda,
# nie trafia do modelu jako prompt — i nie zmienia session_id, więc followupy dalej
# wznawiają tę samą sesję, tyle że mniejszą.
class CompactReviewJob < ApplicationJob
  queue_as :default
  COMMAND = "/compact".freeze

  def perform(review, previous_status, session_factory: default_session_factory)
    config = review.effective_claude_config
    base = review.resumable_session_run(config)
    raise "Brak sesji do skompaktowania na koncie #{Review.claude_config_label(config)}" if base.nil?

    run = review.claude_runs.create!(kind: "compact", claude_config: config,
                                     resume_session_id: base.session_id)
    session_factory.call(run).call(COMMAND)
  rescue StandardError => e
    # Świadomie bez fail!: nieudana kompakcja niczego nie psuje — review dalej ma
    # swój wynik i swoją sesję. Wrzucenie go w „failed" podstawiłoby pod „Ponów"
    # i „Przełącz konto" ostatni run kindu `compact`, a te ścieżki umieją wznowić
    # tylko describe/review/followup i dla nieznanego kindu odpalają describe —
    # czyli skasowałyby opis gotowego review za to, że kompakcja się nie udała.
    # Powód jest widoczny w karcie kontekstu, bo runner zapisał go na runie.
    Rails.logger.warn("Compact review #{review.id}: #{e.message}")
  ensure
    # Review mógł zostać usunięty z dashboardu w trakcie działania joba.
    review.update!(status: previous_status) if Review.exists?(review.id)
  end
end
