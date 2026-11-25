# Uzgodnienie wyniku review z werdyktami weryfikatora i zgodnością z zadaniem: wznawia
# sesję review i pozwala jej rozstrzygnąć znaleziska obalone/sporne oraz poprawić (z dowodem)
# oceny zgodności. Cykl poboczny jak CompactReviewJob: pożycza status „reviewing" na czas
# sesji (blokuje inne akcje na review) i oddaje poprzedni.
#
# Run (z previous_status) zakłada już kontroler: po restarcie z jobem jeszcze w kolejce
# OrphanedRunsCleanup musi wiedzieć, że „reviewing" jest pożyczone przez uzgodnienie.
class ReconcileReviewJob < ApplicationJob
  queue_as :default

  def perform(review, run_id, session_factory: default_session_factory)
    run = review.claude_runs.find_by(id: run_id)
    # Odzysk po restarcie mógł już zamknąć ten run i oddać status — wtedy nic do roboty,
    # a ensure niżej nadpisałby status, który od tamtej pory mógł się zmienić.
    return unless run&.status == "pending"

    reconcile(review, run, session_factory)
  end

  private

  def reconcile(review, run, session_factory)
    config = review.effective_claude_config
    # Bez sesji na tym koncie (np. po przełączeniu) sesja startuje świeża i dostaje
    # kontekst z promptu.
    base = review.resumable_session_run(config)
    run.update!(claude_config: config, resume_session_id: base&.session_id)
    session_factory.call(run).call(PromptBuilder.reconcile(review, resumed: base.present?))
    ReconcileResultImporter.call(review, written_after: run.created_at)
  rescue StandardError => e
    # Świadomie bez fail!, mark_reviewed! i task_fit: nieudane uzgodnienie niczego nie psuje —
    # review dalej ma swój wynik. „failed" podstawiłoby pod „Ponów" ostatni run kindu
    # `reconcile`, którego te ścieżki nie umieją wznowić. Powód ląduje na runie — panel
    # pokazuje go przy przycisku uzgodnienia.
    Rails.logger.warn("Reconcile review #{review.id}: #{e.message}")
    record_failure(run, e)
  ensure
    # Review mógł zostać usunięty z dashboardu w trakcie działania joba. Zmiana statusu
    # odświeża panel przez callback after_update_commit.
    review.update!(status: run.previous_status.presence || "reviewed") if Review.exists?(review.id)
  end

  # Porażkę sesji runner już zapisał (failed/aborted z powodem) — tego nie ruszamy.
  # Sesja, która skończyła się sukcesem, ale nie zostawiła poprawnego reconcile.json,
  # to też porażka uzgodnienia: bez tego run świeciłby „succeeded", a wynik się nie zmienił.
  def record_failure(run, error)
    return unless run.status.in?(%w[pending running succeeded]) && ClaudeRun.exists?(run.id)

    run.update!(status: "failed", error_message: error.message, finished_at: run.finished_at || Time.current)
  end
end
