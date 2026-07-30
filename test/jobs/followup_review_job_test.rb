require "test_helper"

class FollowupReviewJobTest < ActiveSupport::TestCase
  setup do
    @config = Dir.mktmpdir
    @workdir = Dir.mktmpdir
    @review = reviews(:pr_review)
    @review.update!(status: "reviewed", worktree_path: @workdir, summary: "Stare podsumowanie")
    # update_column, nie update!: @config to tmpdir testowy, nie jeden z dwóch
    # prawdziwych configów z listy — walidacja inclusion na claude_config (dodana
    # do utwardzenia formularza) nie ma tu czego pilnować, bo to zaślepka na
    # katalog na dysku, a nie wartość wybieraną w UI.
    @review.update_column(:claude_config, @config)
    @base_run = succeeded_run("review", "sess-base")
    FileUtils.rm_rf(@review.artifacts_dir)
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  teardown do
    FileUtils.remove_entry(@config)
    FileUtils.remove_entry(@workdir)
  end

  # Sesja istnieje dla joba tylko wtedy, gdy jej plik leży pod bieżącym configiem.
  def succeeded_run(kind, session_id, config: @config)
    run = @review.claude_runs.create!(kind: kind, claude_config: config, status: "succeeded", session_id: session_id)
    path = run.session_file(config)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, "{}")
    run
  end

  def session_writing_result(payload, seen_prompts)
    path = @review.artifacts_dir.join("result.json")
    lambda do |_run|
      Object.new.tap do |s|
        s.define_singleton_method(:call) do |prompt|
          seen_prompts << prompt
          File.write(path, payload.to_json)
          "done"
        end
      end
    end
  end

  test "wznawia sesję bazową, przekazuje uwagi i importuje zaktualizowany wynik" do
    prompts = []
    FollowupReviewJob.perform_now(@review, "Znalezisko o teście to false positive",
                                  session_factory: session_writing_result({ summary: "Nowe. **Po dyskusji:** usunięto", findings: [], playwright: nil }, prompts))
    @review.reload
    followup = @review.claude_runs.where(kind: "followup").sole
    assert_equal(
      { status: "reviewed", summary: "Nowe. **Po dyskusji:** usunięto", resume: "sess-base",
        user_message: "Znalezisko o teście to false positive" },
      { status: @review.status, summary: @review.summary, resume: followup.resume_session_id,
        user_message: followup.user_message }
    )
    assert_includes prompts.sole, "Znalezisko o teście to false positive"
    assert_not_includes prompts.sole, "Kontekst poprzedniego review", "wznowiona sesja niesie własną historię"
  end

  test "kolejny followup wznawia sesję poprzedniego followupu" do
    succeeded_run("followup", "sess-f1")
    prompts = []
    FollowupReviewJob.perform_now(@review, "jeszcze jedno",
                                  session_factory: session_writing_result({ summary: "OK", findings: [], playwright: nil }, prompts))
    assert_equal "sess-f1", @review.claude_runs.where(kind: "followup").order(:id).last.resume_session_id
  end

  # To jest sedno zmiany: samo "najnowszy" nie wystarczy, jeśli jego plik zniknął
  # (np. skasowany ręcznie albo z drugiego configu przeniesiono tylko część historii).
  # Regres do zwykłego `.last` przeszedłby wszystkie inne testy w tym pliku.
  test "nowszy run bez pliku sesji jest pomijany na rzecz starszego, który ma plik" do
    @review.claude_runs.create!(kind: "followup", claude_config: @config, status: "succeeded", session_id: "sess-newer-bez-pliku")
    prompts = []
    FollowupReviewJob.perform_now(@review, "y",
                                  session_factory: session_writing_result({ summary: "OK", findings: [], playwright: nil }, prompts))
    assert_equal "sess-base", @review.claude_runs.where(kind: "followup").order(:id).last.resume_session_id
  end

  # Po przełączeniu konta sesja bazowa leży w drugim configu — `--resume` zwróciłby
  # „No conversation found". Wtedy followup ma ruszyć od zera, a nie polec.
  test "sesja z innego konta nie jest wznawiana — leci świeża sesja" do
    @base_run.update!(claude_config: "/inne-konto")
    @review.update_column(:claude_config, "/inne-konto")
    prompts = []
    FollowupReviewJob.perform_now(@review, "sprawdź poprawki",
                                  session_factory: session_writing_result({ summary: "OK", findings: [], playwright: nil }, prompts))
    followup = @review.claude_runs.where(kind: "followup").sole
    assert_nil followup.resume_session_id
    assert_equal "reviewed", @review.reload.status
  end

  # Sesja bez `--resume` nie zna poprzedniego przebiegu, a prompt każe jej nadpisać
  # cały result.json — bez sekcji kontekstu importer skasowałby dotychczasowe findings
  # i zastąpił je zgadywanką. Konto tu się nie zmienia: plik sesji po prostu zniknął.
  test "brak jakiejkolwiek sesji też kończy się świeżym runem, nie błędem" do
    @base_run.update!(session_id: nil)
    prompts = []
    FollowupReviewJob.perform_now(@review, "x",
                                  session_factory: session_writing_result({ summary: "OK", findings: [], playwright: nil }, prompts))
    assert_nil @review.claude_runs.where(kind: "followup").sole.resume_session_id
    assert_equal "reviewed", @review.reload.status
    assert_includes prompts.sole, "Kontekst poprzedniego review"
    assert_includes prompts.sole, "Stare podsumowanie"
    assert_not_includes prompts.sole, "masz pełny kontekst poprzedniej sesji"
  end
end
