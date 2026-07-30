# Sprząta runy osierocone przez restart. Kluczowe: apka może działać w kilku
# procesach naraz (serwer + bin/rails runner) — run jest sierotą dopiero wtedy,
# gdy jego proces-nadzorca (supervisor_pid) nie żyje. Wtedy dobijamy też sam
# proces claude (pgroup przeżywa restart pumy) i oznaczamy stan w bazie.
class OrphanedRunsCleanup
  def self.call
    ClaudeRun.where(status: "running").find_each do |run|
      next if run.supervisor_pid && process_alive?(run.supervisor_pid)

      CommandRunner.kill_group(run.pid) if run.pid && process_alive?(run.pid)
      run.update!(status: "aborted", error_message: "Przerwane restartem aplikacji")
    end

    Review.where(status: %w[describing reviewing]).find_each do |review|
      next if review.claude_runs.where(status: "running").exists?
      next if recover_from_disk(review)

      review.fail!("Przerwane restartem aplikacji — kliknij Ponów")
    end

    # Cykle poboczne (opis zadania, komentarz do zadania) żyją poza statusem review.
    # "running" bez żywej sesji = job przepadł w restarcie; "queued" zostaje w spokoju —
    # zakolejkowany job przeżywa restart w solid_queue i jeszcze się wykona.
    { task_description_status: "describe_task", task_comment_status: "comment_task" }.each do |column, kind|
      Review.where(column => "running").find_each do |review|
        next if review.claude_runs.where(kind: kind, status: "running").exists?

        review.update!(column => "failed")
      end
    end
  end

  # Sesja claude przeżywa restart apki (własny pgroup) i potrafi dokończyć
  # review zapisując result.json — wtedy odzyskujemy wynik zamiast go gubić.
  def self.recover_from_disk(review)
    return false unless review.status == "reviewing" && review.result_on_disk?

    ReviewResultImporter.call(review)
    review.update!(status: "reviewed")
    true
  rescue StandardError
    false
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
