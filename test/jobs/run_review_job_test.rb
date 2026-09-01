require "test_helper"

class RunReviewJobTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:pr_review)
    @review.update!(status: "ready", worktree_path: Dir.tmpdir, scope: { "areas" => %w[functionality], "notes" => "" })
    FileUtils.rm_rf(@review.artifacts_dir)
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  def session_writing_result(payload)
    # Ścieżka w zmiennej lokalnej — define_singleton_method rebinduje self,
    # więc helpery testowe (reviews) nie są dostępne w bloku.
    path = @review.artifacts_dir.join("result.json")
    lambda do |_run|
      Object.new.tap do |s|
        s.define_singleton_method(:call) do |_prompt|
          File.write(path, payload.to_json)
          "done"
        end
      end
    end
  end

  test "sukces: importuje wynik i ustawia reviewed" do
    RunReviewJob.perform_now(@review, github: FakeGithubClient.new, session_factory: session_writing_result(summary: "OK", findings: [], playwright: nil))
    assert_equal "reviewed", @review.reload.status
    assert_equal "OK", @review.summary
  end

  test "sesja nie zapisała result.json → failed z czytelnym komunikatem" do
    factory = ->(_run) { Object.new.tap { |s| s.define_singleton_method(:call) { |_p| "gadanie bez pliku" } } }
    RunReviewJob.perform_now(@review, github: FakeGithubClient.new, session_factory: factory)
    @review.reload
    assert_equal "failed", @review.status
    assert_includes @review.error_message, "result.json"
  end

  test "sesja rzuca Failed → failed" do
    factory = ->(_run) { Object.new.tap { |s| s.define_singleton_method(:call) { |_p| raise ClaudeSessionRunner::Failed, "timeout" } } }
    RunReviewJob.perform_now(@review, github: FakeGithubClient.new, session_factory: factory)
    assert_equal "failed", @review.reload.status
  end

  # Zwis to zwykle chwilowe zacięcie sesji — jedno ponowienie ratuje review
  # bez czekania, aż user zauważy martwy panel.
  test "zwis sesji jest ponawiany raz i drugie podejście może się udać" do
    path = @review.artifacts_dir.join("result.json")
    calls = 0
    factory = lambda do |_run|
      Object.new.tap do |s|
        s.define_singleton_method(:call) do |_prompt|
          calls += 1
          raise ClaudeSessionRunner::Stalled, "cisza" if calls == 1

          File.write(path, { summary: "OK za drugim razem", findings: [], playwright: nil }.to_json)
          "done"
        end
      end
    end
    RunReviewJob.perform_now(@review, github: FakeGithubClient.new, session_factory: factory)
    assert_equal({ calls: 2, status: "reviewed", runs: 2 },
                 { calls: calls, status: @review.reload.status, runs: @review.claude_runs.where(kind: "review").count })
  end

  test "dwa zwisy z rzędu kończą się failed — bez pętli ponowień" do
    calls = 0
    factory = lambda do |_run|
      Object.new.tap do |s|
        s.define_singleton_method(:call) { |_p| calls += 1; raise ClaudeSessionRunner::Stalled, "cisza" }
      end
    end
    RunReviewJob.perform_now(@review, github: FakeGithubClient.new, session_factory: factory)
    assert_equal({ calls: RunReviewJob::MAX_ATTEMPTS, status: "failed" }, { calls: calls, status: @review.reload.status })
  end

  # Ten sam wyścig co w FollowupReviewJob: spóźniony run nie może nadpisać stanu,
  # w który review poszedł dalej w międzyczasie (np. usunięty i odtworzony cykl).
  test "spóźniony błąd nie nadpisuje statusu po wysłanej decyzji" do
    review_id = @review.id
    factory = lambda do |_run|
      Object.new.tap do |s|
        s.define_singleton_method(:call) do |_prompt|
          Review.find(review_id).update!(status: "decided")
          raise ClaudeSessionRunner::Failed, "Timeout po 1800s"
        end
      end
    end
    RunReviewJob.perform_now(@review, github: FakeGithubClient.new, session_factory: factory)
    assert_equal [ "decided", nil ], [ @review.reload.status, @review.error_message ]
  end

  test "zwykły Failed nie jest ponawiany" do
    calls = 0
    factory = lambda do |_run|
      Object.new.tap do |s|
        s.define_singleton_method(:call) { |_p| calls += 1; raise ClaudeSessionRunner::Failed, "exit 1" }
      end
    end
    RunReviewJob.perform_now(@review, github: FakeGithubClient.new, session_factory: factory)
    assert_equal({ calls: 1, status: "failed" }, { calls: calls, status: @review.reload.status })
  end


  # Wątek na PR-ze: moja pinezka i odpowiedź autora pod nią.
  def answered_thread
    [ { "id" => 1, "path" => "app/x.rb", "line" => 3, "position" => 2, "subject_type" => "line",
        "user" => "reviewerka", "body" => "moja uwaga", "created_at" => "2026-08-29T10:00:00Z" },
      { "id" => 2, "in_reply_to_id" => 1, "user" => "autorka", "created_at" => "2026-08-30T10:00:00Z",
        "body" => "Świadome — nie przywracam." } ]
  end

  # Świeże review też nie może zgłaszać rzeczy już wyjaśnionej na PR-ze.
  test "prompt review niesie rozmowę z PR-a" do
    prompts = []
    factory = lambda do |_run|
      path = @review.artifacts_dir.join("result.json")
      Object.new.tap do |s|
        s.define_singleton_method(:call) do |prompt|
          prompts << prompt
          File.write(path, { summary: "OK", findings: [], playwright: nil }.to_json)
          "done"
        end
      end
    end

    RunReviewJob.perform_now(@review, github: FakeGithubClient.new(review_comments: answered_thread),
                                      session_factory: factory)

    assert_includes prompts.sole, "Dyskusja na PR-ze"
    assert_includes prompts.sole, "Świadome — nie przywracam."
  end
end
