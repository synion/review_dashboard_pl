class PlaywrightRunJob < ApplicationJob
  queue_as :default

  TIMEOUT = 1800

  def perform(run, runner: CommandRunner)
    review = run.review
    output_path = review.artifacts_dir.join("playwright_#{run.id}.log")
    env = run.mode == "headless" ? { "HEADLESS" => "1" } : {}
    workdir = review.worktree_path.presence || review.project.repo_path
    result = runner.run(CommandRunner.zsh(review.playwright_command), env: env, chdir: workdir, timeout: TIMEOUT)
    FileUtils.mkdir_p(review.artifacts_dir)
    File.write(output_path, result.stdout + result.stderr)
    run.update!(status: result.success? ? "passed" : "failed", exit_code: result.exit_code, output_path: output_path.to_s)
  rescue StandardError => e
    run.update!(status: "failed", output_path: output_path.to_s)
    FileUtils.mkdir_p(review.artifacts_dir)
    File.write(output_path, "Błąd uruchomienia: #{e.message}")
  ensure
    # Panel renderuje playwright_runs — po zakończeniu odśwież go jawnie
    # (zmiana była na PlaywrightRun, więc broadcast Review się nie odpali sam).
    review.broadcast_panel! if Review.exists?(review.id)
  end
end
