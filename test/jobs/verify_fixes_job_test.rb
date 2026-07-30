require "test_helper"

class VerifyFixesJobTest < ActiveSupport::TestCase
  class FakeGithub
    attr_reader :calls

    def initialize(head:, error: nil)
      @head = head
      @error = error
      @calls = []
    end

    def pr_head_sha(pr_url, repo_dir:)
      @calls << pr_url
      raise GithubClient::Error, @error if @error

      @head
    end
  end

  class FakeSession
    attr_reader :prompts

    def initialize(review) = (@review = review; @prompts = [])

    def call(prompt)
      @prompts << prompt
      @review.artifacts_dir.join("fixes.json").write(
        { fixes: [ { id: @review.findings.first.id, status: "implemented", note: "guard dodany" } ] }.to_json
      )
      "gotowe"
    end
  end

  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "decided", decision: "comment", decision_head_sha: "aaa1111",
                    branch: "sl-fix-vat", worktree_path: Dir.tmpdir)
    @finding = @review.findings.create!(priority: "critical", title: "nil w kalkulacji", body: "x")
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  teardown { FileUtils.rm_rf(@review.artifacts_dir) }

  def run_job(github, session = FakeSession.new(@review))
    VerifyFixesJob.perform_now(@review, github: github, session_factory: ->(_run) { session })
    session
  end

  test "should verify the findings against the code pushed after the decision" do
    session = run_job(FakeGithub.new(head: "bbb2222"))

    assert_equal "implemented", @finding.reload.fix_status
    assert @review.reload.fixes_checked_at.present?
    assert_equal [ "verify_fixes" ], @review.claude_runs.map(&:kind)
    assert_includes session.prompts.sole, "aaa1111", "prompt musi podać punkt odniesienia"
  end

  # Sesja kosztuje tyle samo niezależnie od tego, czy jest co czytać — a odpowiedź
  # „autor nic nie wypchnął" da się dać bez modelu.
  test "should skip the session when nothing was pushed since the decision" do
    session = run_job(FakeGithub.new(head: "aaa1111"))

    assert_empty session.prompts
    assert_empty @review.claude_runs
    assert @review.reload.fixes_checked_at.present?
    assert_nil @finding.reload.fix_status
  end

  # Padnięty gh nie może wmówić, że autor nic nie zmienił — wtedy pytamy sesję.
  test "should still ask the session when GitHub is unreachable" do
    session = run_job(FakeGithub.new(head: nil, error: "gh padł"))

    assert_equal 1, session.prompts.size
    assert_equal "implemented", @finding.reload.fix_status
  end

  test "should do nothing for a review that has nothing to verify" do
    @review.update!(status: "reviewed")
    github = FakeGithub.new(head: "bbb2222")

    run_job(github)

    assert_empty github.calls
    assert_empty @review.claude_runs
  end

  # Cykl poboczny: porażka weryfikacji nie może zamazać wysłanej decyzji ani znalezisk.
  test "should not fail the review when the session leaves no result" do
    silent = Object.new
    def silent.call(_prompt) = "nic nie zapisałem"

    VerifyFixesJob.perform_now(@review, github: FakeGithub.new(head: "bbb2222"),
                                        session_factory: ->(_run) { silent })

    assert_equal "decided", @review.reload.status
    assert_nil @review.error_message
    assert_nil @finding.reload.fix_status
  end
end
