require "test_helper"

class TaskFitJobTest < ActiveSupport::TestCase
  class FakeSession
    attr_reader :prompts

    def initialize(review, payload) = (@review = review; @payload = payload; @prompts = [])

    def call(prompt)
      @prompts << prompt
      @review.artifacts_dir.join("task_fit.json").write(@payload.to_json) if @payload
      "gotowe"
    end
  end

  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "reviewed", branch: "sl-2fa", worktree_path: Dir.tmpdir,
                    task_criteria: { "criteria" => [ { "id" => "ac1", "text" => "Kod dochodzi" } ], "traps" => [] },
                    task_fit_status: "queued")
    FileUtils.rm_rf(@review.artifacts_dir)
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  teardown { FileUtils.rm_rf(@review.artifacts_dir) }

  def run_job(payload)
    session = FakeSession.new(@review, payload)
    TaskFitJob.perform_now(@review, github: FakeGithubClient.new, session_factory: ->(_run) { session })
    @review.reload
    session
  end

  test "świeża sesja pisze task_fit.json, importer daje werdykt, status review nietknięty" do
    session = run_job("evidence_found" => true, "criteria" => [ { "id" => "ac1", "status" => "unmet", "note" => "brak" } ])
    assert_equal "ready", @review.task_fit_status
    assert_equal "misses", @review.task_fit_verdict
    assert_equal "reviewed", @review.status
    run = @review.claude_runs.sole
    assert_equal [ "task_fit", nil ], [ run.kind, run.resume_session_id ]
    assert_includes session.prompts.sole, "id ac1"
  end

  # Cykl poboczny: porażka nie może zamazać review ani poprzedniego werdyktu.
  test "sesja bez pliku: failed, stary werdykt zostaje" do
    @review.update!(task_fit: { "verdict" => "fits" }, task_fit_status: "ready")
    run_job(nil)
    assert_equal "failed", @review.task_fit_status
    assert_equal({ "verdict" => "fits" }, @review.task_fit)
    assert_equal "reviewed", @review.status
    assert_nil @review.error_message
  end

  test "bez listy AC nic nie robi" do
    @review.update!(task_criteria: nil, task_fit_status: "skipped")
    session = run_job("evidence_found" => true)
    assert_empty session.prompts
    assert_empty @review.claude_runs
  end
end
