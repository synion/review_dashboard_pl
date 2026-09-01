require "test_helper"

class VerifyFixesJobTest < ActiveSupport::TestCase
  DECIDED_AT = Time.zone.parse("2026-08-30T12:00:00Z")

  class FakeSession
    attr_reader :prompts

    def initialize(review, status: "implemented") = (@review = review; @status = status; @prompts = [])

    def call(prompt)
      @prompts << prompt
      @review.artifacts_dir.join("fixes.json").write(
        { fixes: [ { id: @review.findings.first.id, status: @status, note: "guard dodany" } ] }.to_json
      )
      "gotowe"
    end
  end

  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "decided", decision: "comment", decision_head_sha: "aaa1111",
                    branch: "sl-fix-vat", worktree_path: Dir.tmpdir, decided_at: DECIDED_AT)
    @finding = @review.findings.create!(priority: "critical", title: "nil w kalkulacji", body: "x")
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  teardown { FileUtils.rm_rf(@review.artifacts_dir) }

  # Wątek na GitHubie założony moją pinezką do @finding, z odpowiedzią autora.
  def author_reply(created_at:, body: "Zostawiam świadomie — dług z mastera.")
    pin = { "id" => 5, "path" => "app/models/invoice.rb", "line" => 12, "side" => "RIGHT", "position" => 3,
            "subject_type" => "line", "user" => "reviewerka", "created_at" => "2026-08-29T10:00:00Z",
            "body" => "#{InlineComments.header_for(@finding)}\n\n#{@finding.body}" }
    [ pin, pin.merge("id" => 6, "in_reply_to_id" => 5, "user" => "autorka",
                     "body" => body, "created_at" => created_at) ]
  end

  def run_job(github, session = FakeSession.new(@review))
    VerifyFixesJob.perform_now(@review, github: github, session_factory: ->(_run) { session })
    session
  end

  test "should verify the findings against the code pushed after the decision" do
    session = run_job(FakeGithubClient.new(head: "bbb2222"))

    assert_equal "implemented", @finding.reload.fix_status
    assert @review.reload.fixes_checked_at.present?
    assert_equal [ "verify_fixes" ], @review.claude_runs.map(&:kind)
    assert_includes session.prompts.sole, "aaa1111", "prompt musi podać punkt odniesienia"
  end

  # Sesja kosztuje tyle samo niezależnie od tego, czy jest co czytać — a odpowiedź
  # „autor nic nie wypchnął" da się dać bez modelu.
  test "should skip the session when nothing was pushed since the decision" do
    session = run_job(FakeGithubClient.new(head: "aaa1111"))

    assert_empty session.prompts
    assert_empty @review.claude_runs
    assert @review.reload.fixes_checked_at.present?
    assert_nil @finding.reload.fix_status
  end

  # Padnięty gh nie może wmówić, że autor nic nie zmienił — wtedy pytamy sesję.
  test "should still ask the session when GitHub is unreachable" do
    session = run_job(FakeGithubClient.new(head: nil, head_error: "gh padł"))

    assert_equal 1, session.prompts.size
    assert_equal "implemented", @finding.reload.fix_status
  end

  test "should do nothing for a review that has nothing to verify" do
    @review.update!(status: "reviewed")
    github = FakeGithubClient.new(head: "bbb2222")

    run_job(github)

    assert_empty github.head_calls
    assert_empty @review.claude_runs
  end

  # Cykl poboczny: porażka weryfikacji nie może zamazać wysłanej decyzji ani znalezisk.
  test "should not fail the review when the session leaves no result" do
    silent = Object.new
    def silent.call(_prompt) = "nic nie zapisałem"

    VerifyFixesJob.perform_now(@review, github: FakeGithubClient.new(head: "bbb2222"),
                                        session_factory: ->(_run) { silent })

    assert_equal "decided", @review.reload.status
    assert_nil @review.error_message
    assert_nil @finding.reload.fix_status
  end

  # Sedno zmiany: autor nie ruszył kodu, tylko odpisał pod pinezką. Dawniej sesja
  # w ogóle nie ruszała (SHA bez zmian), a znalezisko zostawało bez werdyktu —
  # przy kolejnym review wracało do autora jako „nie zrobiłeś".
  test "should ask the session when the author replied without pushing anything" do
    github = FakeGithubClient.new(head: "aaa1111", review_comments: author_reply(created_at: "2026-08-31T09:00:00Z"))
    session = run_job(github, FakeSession.new(@review, status: "answered"))

    assert_equal 1, session.prompts.size
    assert_equal "answered", @finding.reload.fix_status
    assert_includes session.prompts.sole, "Zostawiam świadomie — dług z mastera."
  end

  # Odpowiedź sprzed decyzji już przy niej widziałem — nie jest powodem do sesji.
  test "should still skip the session when the only reply predates the decision" do
    github = FakeGithubClient.new(head: "aaa1111", review_comments: author_reply(created_at: "2026-08-29T11:00:00Z"))
    session = run_job(github)

    assert_empty session.prompts
    assert_nil @finding.reload.fix_status
  end
end
