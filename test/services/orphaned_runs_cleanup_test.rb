require "test_helper"

class OrphanedRunsCleanupTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:pr_review)
    # Obrona przed cudzym result.json na wspólnej ścieżce fixture'a: recover_from_disk
    # uznałby go za wynik do odzyskania i review wyszedłby „reviewed" zamiast „failed".
    FileUtils.rm_rf(@review.artifacts_dir)
  end

  test "run z martwym nadzorcą: dobija proces claude i oznacza jako przerwany" do
    @review.update!(status: "reviewing")
    run = @review.claude_runs.create!(kind: "review", claude_config: "/x", status: "running",
                                      pid: Process.pid, supervisor_pid: 999_999_999)
    killed = []
    CommandRunner.stub :kill_group, ->(pid, **) { killed << pid } do
      OrphanedRunsCleanup.call
    end
    assert_equal(
      { killed: [ Process.pid ], run_status: "aborted", review_status: "failed" },
      { killed: killed, run_status: run.reload.status, review_status: @review.reload.status }
    )
    assert_includes @review.error_message, "restartem"
  end

  test "run z żywym nadzorcą (inny proces apki) zostaje nietknięty" do
    @review.update!(status: "reviewing")
    run = @review.claude_runs.create!(kind: "review", claude_config: "/x", status: "running",
                                      pid: 12_345, supervisor_pid: Process.pid)
    OrphanedRunsCleanup.call
    assert_equal(
      { run_status: "running", review_status: "reviewing" },
      { run_status: run.reload.status, review_status: @review.reload.status }
    )
  end

  test "osierocony opis zadania w running dostaje failed, queued zostaje w spokoju" do
    running = reviews(:pr_review)
    running.update!(task_description_status: "running")
    running.claude_runs.create!(kind: "describe_task", claude_config: "/x", status: "running",
                                supervisor_pid: 999_999_999)
    queued = reviews(:task_only)
    queued.update!(task_description_status: "queued")

    CommandRunner.stub :kill_group, ->(*_args, **) {} do
      OrphanedRunsCleanup.call
    end
    assert_equal "failed", running.reload.task_description_status
    assert_equal "queued", queued.reload.task_description_status,
                 "zakolejkowany job przeżywa restart w solid_queue — nie wolno go uśmiercać"
  end

  test "pracujący opis zadania z żywym nadzorcą zostaje w running" do
    @review.update!(task_description_status: "running")
    @review.claude_runs.create!(kind: "describe_task", claude_config: "/x", status: "running",
                                pid: 12_345, supervisor_pid: Process.pid)
    OrphanedRunsCleanup.call
    assert_equal "running", @review.reload.task_description_status
  end

  test "run bez supervisor_pid traktowany jako sierota" do
    run = @review.claude_runs.create!(kind: "review", claude_config: "/x", status: "running", supervisor_pid: nil)
    OrphanedRunsCleanup.call
    assert_equal "aborted", run.reload.status
  end

  test "reviewing z result.json na dysku odzyskuje wynik zamiast failować" do
    @review.update!(status: "reviewing")
    FileUtils.mkdir_p(@review.artifacts_dir)
    File.write(@review.artifacts_dir.join("result.json"),
               { summary: "Odzyskane", findings: [ { priority: "minor", title: "A", body: "", file: "" } ], playwright: nil }.to_json)
    OrphanedRunsCleanup.call
    @review.reload
    assert_equal({ status: "reviewed", summary: "Odzyskane", findings: [ "A" ] },
                 { status: @review.status, summary: @review.summary, findings: @review.findings.map(&:title) })
  ensure
    FileUtils.rm_rf(@review.artifacts_dir)
  end

  test "describing bez żadnego runa jest oznaczany jako przerwany" do
    @review.update!(status: "describing")
    OrphanedRunsCleanup.call
    assert_equal "failed", @review.reload.status
  end

  test "nie dotyka review w stanach spoczynkowych" do
    @review.update!(status: "ready")
    OrphanedRunsCleanup.call
    assert_equal "ready", @review.reload.status
  end
end
