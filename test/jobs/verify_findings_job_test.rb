require "test_helper"

class VerifyFindingsJobTest < ActiveSupport::TestCase
  class FakeSession
    attr_reader :prompts

    def initialize(review) = (@review = review; @prompts = [])

    def call(prompt)
      @prompts << prompt
      @review.artifacts_dir.join("verdicts.json").write(
        { verdicts: [ { id: @review.findings.first.id, verdict: "refuted", note: "guard już jest" } ] }.to_json
      )
      "gotowe"
    end
  end

  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "reviewed", branch: "sl-fix-vat", worktree_path: Dir.tmpdir)
    @finding = @review.findings.create!(priority: "critical", title: "nil w kalkulacji", body: "x")
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  teardown { FileUtils.rm_rf(@review.artifacts_dir) }

  def run_job(session = FakeSession.new(@review))
    VerifyFindingsJob.perform_now(@review, session_factory: ->(_run) { session })
    session
  end

  test "should verify the findings with a fresh session and import the verdicts" do
    session = run_job

    assert_equal "refuted", @finding.reload.verdict
    assert @review.reload.findings_verified_at.present?
    assert_equal [ "verify_findings" ], @review.claude_runs.map(&:kind)
    assert_includes session.prompts.sole, "id #{@finding.id}"
  end

  test "should store the model, effort and config override on the run" do
    VerifyFindingsJob.perform_now(@review, model: "opus", effort: "max", claude_config: "/Users/dev/.claude-b",
                                           session_factory: ->(_run) { FakeSession.new(@review) })

    run = @review.claude_runs.sole
    assert_equal [ "opus", "max", "/Users/dev/.claude-b" ], [ run.model, run.effort, run.claude_config ]
  end

  test "should do nothing for a review that has nothing to verify" do
    @review.update!(status: "created")

    session = run_job

    assert_empty session.prompts
    assert_empty @review.claude_runs
  end

  # Cykl poboczny: porażka weryfikacji nie może zamazać wyniku review ani znalezisk.
  test "should not fail the review when the session leaves no result" do
    silent = Object.new
    def silent.call(_prompt) = "nic nie zapisałem"

    VerifyFindingsJob.perform_now(@review, session_factory: ->(_run) { silent })

    assert_equal "reviewed", @review.reload.status
    assert_nil @review.error_message
    assert_nil @finding.reload.verdict
  end
end
