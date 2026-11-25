# Sprząta runy osierocone przez restart. Kluczowe: apka może działać w kilku
# procesach naraz (serwer + bin/rails runner) — run jest sierotą dopiero wtedy,
# gdy jego proces-nadzorca (supervisor_pid) nie żyje. Wtedy dobijamy też sam
# proces claude (pgroup przeżywa restart pumy) i oznaczamy stan w bazie.
class OrphanedRunsCleanup
  # Cykle poboczne żyją poza statusem review: kolumna statusu → rodzaj sesji.
  SIDE_CYCLES = { task_description_status: "describe_task", task_comment_status: "comment_task",
                  task_fit_status: "task_fit" }.freeze

  def self.call
    abort_dead_runs

    Review.where(status: %w[describing reviewing]).find_each do |review|
      next if review.claude_runs.where(status: "running").exists?
      next if recover_from_disk(review)

      review.fail!("Przerwane restartem aplikacji — kliknij Ponów")
    end

    # "running" bez żywej sesji = job przepadł w restarcie; "queued" zostaje w spokoju —
    # zakolejkowany job przeżywa restart w solid_queue i jeszcze się wykona.
    SIDE_CYCLES.each do |column, kind|
      Review.where(column => "running").find_each do |review|
        next if review.claude_runs.where(kind: kind, status: "running").exists?

        review.update!(column => "failed")
      end
    end
  end

  def self.abort_dead_runs
    ClaudeRun.where(status: "running").find_each do |run|
      next if run.supervisor_pid && process_alive?(run.supervisor_pid)

      CommandRunner.kill_group(run.pid) if run.pid && process_alive?(run.pid)
      run.update!(status: "aborted", error_message: "Przerwane restartem aplikacji")
      fail_side_cycle(run)
    end
  end

  # Job sesji cyklu pobocznego ginie razem z workerem (Solid Queue go oblewa, nikt
  # nie ponawia), więc „running" zostałby na zawsze — panel bez przycisku ponowienia.
  def self.fail_side_cycle(run)
    column = SIDE_CYCLES.key(run.kind)
    run.review.update!(column => "failed") if column && run.review[column] == "running"
  end

  # Sesja claude przeżywa restart apki (własny pgroup) i potrafi dokończyć
  # review zapisując result.json — wtedy odzyskujemy wynik zamiast go gubić.
  # Tylko plik zapisany po starcie przerwanego runa: starszy to wynik poprzedniego
  # przebiegu, a nie dokończona praca.
  def self.recover_from_disk(review)
    run = interrupted_reconcile_run(review)
    return recover_reconcile(review, run) if run

    return false unless review.status == "reviewing" && review.result_on_disk?

    ReviewResultImporter.call(review, written_after: review.last_lifecycle_run&.created_at)
    review.mark_reviewed!
    true
  rescue StandardError
    false
  end

  # Uzgodnienie, któremu restart przerwał pracę albo które czekało w kolejce. Świadomie
  # nie „ostatni run": w trakcie uzgodnienia mógł wystartować run poboczny (task_fit,
  # opis zadania), a stare, zakończone uzgodnienie zostaje ostatnim, gdy followup czeka
  # w kolejce bez runa. Przerwane = pending/running albo aborted bez finished_at
  # (tak zostawia go abort_dead_runs; recover_reconcile domyka finished_at, żeby nie
  # rozpoznać go drugi raz). I tylko wtedy, gdy po nim nie ruszył krok cyklu ani compact.
  def self.interrupted_reconcile_run(review)
    run = review.claude_runs.where(kind: "reconcile").order(:id).last
    return unless run
    return unless run.status.in?(%w[pending running]) || (run.status == "aborted" && run.finished_at.nil?)

    newer = review.claude_runs.where(kind: ClaudeRun::LIFECYCLE_KINDS + [ "compact" ]).where("id > ?", run.id)
    run unless newer.exists?
  end

  # Uzgodnienie to cykl poboczny na pożyczonym statusie „reviewing": nie wolno go kończyć
  # ścieżką review (result.json to wynik sprzed uzgodnienia, a mark_reviewed! odpaliłby
  # task_fit). Importujemy reconcile.json, o ile sesja zdążyła go zapisać, i oddajemy status.
  def self.recover_reconcile(review, run)
    begin
      ReconcileResultImporter.call(review, written_after: run.created_at)
    rescue StandardError => e
      # Brak pliku, ucięty JSON (sesja ubita w trakcie zapisu) czy błąd walidacji: wynik
      # review zostaje taki, jaki był. Nigdy fail! — „Ponów" nie umie wznowić uzgodnienia.
      Rails.logger.warn("Odzysk uzgodnienia review #{review.id}: #{e.message}")
    end
    # Job czekający jeszcze w kolejce zobaczy zamknięty run i nic nie zrobi — inaczej
    # po starcie oddałby status, który od tej pory mógł się już zmienić.
    run.update!(status: "aborted", finished_at: Time.current,
                error_message: run.error_message.presence || "Przerwane restartem aplikacji")
    review.update!(status: run.previous_status.presence || "reviewed")
    true
  end

  def self.process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
end
