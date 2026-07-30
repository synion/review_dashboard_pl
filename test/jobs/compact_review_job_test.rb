require "test_helper"

class CompactReviewJobTest < ActiveSupport::TestCase
  setup do
    @config = Dir.mktmpdir
    @review = reviews(:pr_review)
    @review.update!(status: "reviewing", worktree_path: Dir.tmpdir)
    # update_column: @config to tmpdir testowy, nie jeden z dwóch prawdziwych
    # configów z listy — walidacja inclusion nie ma tu czego pilnować.
    @review.update_column(:claude_config, @config)
    @base = succeeded_run("followup", "sess-base")
  end

  teardown { FileUtils.remove_entry(@config) }

  # Sesja istnieje dla joba tylko wtedy, gdy jej plik leży pod bieżącym configiem.
  def succeeded_run(kind, session_id, config: @config)
    run = @review.claude_runs.create!(kind: kind, claude_config: config, status: "succeeded", session_id: session_id)
    path = run.session_file(config)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, "{}")
    run
  end

  def recording_session(prompts)
    lambda do |_run|
      Object.new.tap do |session|
        session.define_singleton_method(:call) do |prompt|
          prompts << prompt
          "skompaktowano"
        end
      end
    end
  end

  test "wznawia sesję bazową promptem /compact i przywraca poprzedni status" do
    prompts = []
    CompactReviewJob.perform_now(@review, "reviewed", session_factory: recording_session(prompts))
    run = @review.claude_runs.where(kind: "compact").sole
    assert_equal({ prompt: "/compact", resume: "sess-base", status: "reviewed", config: @config },
                 { prompt: prompts.sole, resume: run.resume_session_id, status: @review.reload.status,
                   config: run.claude_config })
  end

  # Prompt to komenda CLI, nie prompt do modelu — przepuszczenie jej przez
  # PromptBuilder (styl, kontekst review) tylko by ją popsuło.
  test "prompt nie jest wzbogacany o kontekst review" do
    prompts = []
    CompactReviewJob.perform_now(@review, "reviewed", session_factory: recording_session(prompts))
    assert_equal "/compact", prompts.sole
  end

  test "brak sesji na bieżącym koncie nie zostawia review w reviewing" do
    @base.update!(session_id: nil)
    prompts = []
    CompactReviewJob.perform_now(@review, "reviewed", session_factory: recording_session(prompts))
    assert_equal "reviewed", @review.reload.status
    assert_empty prompts, "bez sesji bazowej nie ma czego wznawiać"
    assert_empty @review.claude_runs.where(kind: "compact")
  end

  # Nieudana kompakcja niczego nie psuje — review dalej ma wynik i sesję. Gdyby
  # lądowało w „failed", „Ponów" i „Przełącz konto" wznowiłyby ostatni run kindu
  # compact, czyli — po fallbacku — describe, kasując opis gotowego review.
  test "padnięta sesja przywraca poprzedni status, zamiast wrzucać review w failed" do
    factory = ->(_run) { Object.new.tap { |s| s.define_singleton_method(:call) { |_p| raise ClaudeSessionRunner::Failed, "limit konta" } } }
    CompactReviewJob.perform_now(@review, "reviewed", session_factory: factory)
    assert_equal "reviewed", @review.reload.status
  end
end
