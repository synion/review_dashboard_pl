# Ocenia świeżą sesją (bez --resume), czy PR rozwiązuje zgłoszone zadanie: premisa
# z dowodem, status każdego AC, pułapki i wymogu procesu. Werdykt liczy importer.
# Cykl poboczny: nie rusza statusu review ani znalezisk z review, tylko dokłada
# własne (source task_fit). Kolejkowany po każdym review i followupie oraz z przycisku.
class TaskFitJob < ApplicationJob
  queue_as :default

  def perform(review, session_factory: default_session_factory, github: GithubClient.new)
    unless review.task_fit_possible?
      # Pracuje inna sesja - status należy do niej. Inaczej „queued" zostałby na
      # zawsze (panel „Sprawdzam…" bez końca), bo nikt inny go już nie zdejmie.
      review.update!(task_fit_status: "failed") if review.task_fit_status == "queued" && !review.task_fit_in_progress?
      return
    end

    review.update!(task_fit_status: "running")
    run = review.claude_runs.create!(kind: "task_fit", claude_config: review.effective_claude_config)
    # Snapshot PR-a sprzed chwili (review/followup pobrały go tuż przed) wystarcza -
    # pięć spawnów `gh` drugi raz w minutę nic nowego nie przyniesie. Stęchły albo
    # brakujący pobieramy od nowa.
    snapshot = PrSnapshot.load(review)
    snapshot = PrSnapshot.refresh(review, client: github) if snapshot.nil? || snapshot.stale?(review)
    discussion = snapshot && PrDiscussion.new(snapshot)
    session_factory.call(run).call(PromptBuilder.task_fit(review, discussion: discussion))
    TaskFitImporter.call(review)
  rescue StandardError => e
    # Poprzedni werdykt zostaje (stary wynik jest lepszy niż żaden), status mówi,
    # że to nie jest aktualne; powód błędu panel czyta z runa (task_fit_error).
    Rails.logger.warn("TaskFitJob review #{review.id}: #{e.message}")
    # Błąd przed startem sesji (np. padnięty `gh` przy snapshocie) zostawiał run
    # „pending" na zawsze, a ten blokuje każdą kolejną ocenę (task_fit_in_progress?).
    run.update!(status: "failed", finished_at: Time.current, error_message: e.message) if run&.status == "pending"
    mark_failed(review, run) if Review.exists?(review.id)
  end

  private

  # Po restarcie (Review#restart_task_fit!) ubita stara sesja kończy się błędem już
  # PO zakolejkowaniu nowej oceny - jej „failed" nie może zamazać „queued"/„running"
  # następczyni. Status jest nasz tylko, gdy wciąż mówi „running" i nie ma nowszego runa.
  def mark_failed(review, run)
    review.reload
    return unless review.task_fit_status == "running"
    return if run && review.claude_runs.where(kind: "task_fit").where("id > ?", run.id).exists?

    review.update!(task_fit_status: "failed")
  end
end
