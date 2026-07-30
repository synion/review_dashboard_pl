require "test_helper"

class ClaudeRunTest < ActiveSupport::TestCase
  test "log_path i timeout zależą od kind" do
    review = reviews(:pr_review)
    describe_run = review.claude_runs.create!(kind: "describe", claude_config: "/x")
    review_run = review.claude_runs.create!(kind: "review", claude_config: "/x")
    assert_equal review.artifacts_dir.join("describe.log"), describe_run.log_path
    assert_equal review.artifacts_dir.join("review.log"), review_run.log_path
    assert_equal 900, describe_run.timeout_seconds
    assert_equal 3600, review_run.timeout_seconds
  end

  # Dla describe limit całkowity równa się limitowi ciszy — watchdog nie może
  # obiecywać dłuższego okna niż cała sesja.
  test "limit ciszy nie przekracza limitu całkowitego" do
    review = reviews(:pr_review)
    assert_equal 900, review.claude_runs.create!(kind: "describe", claude_config: "/x").idle_timeout_seconds
    assert_equal 900, review.claude_runs.create!(kind: "review", claude_config: "/x").idle_timeout_seconds
  end

  test "resume_command zawiera cd do katalogu sesji, config i session_id" do
    review = reviews(:pr_review)
    review.update!(worktree_path: "/wt")
    run = review.claude_runs.create!(kind: "review", claude_config: "/Users/dev/.claude", session_id: "abc-123")
    assert_equal "cd /wt && CLAUDE_CONFIG_DIR=/Users/dev/.claude claude --resume abc-123", run.resume_command
  end

  test "resume_command bez worktree używa repo projektu" do
    run = reviews(:pr_review).claude_runs.create!(kind: "review", claude_config: "/c", session_id: "abc")
    assert_equal "cd /Users/dev/projects/webapp && CLAUDE_CONFIG_DIR=/c claude --resume abc", run.resume_command
  end

  test "session_file składa ścieżkę z configu, slugu katalogu roboczego i session_id" do
    review = reviews(:pr_review)
    review.update!(worktree_path: "/Users/dev/projects/webapp-jz_recurring_send_email")
    run = review.claude_runs.create!(kind: "review", claude_config: "/c", session_id: "abc-123")
    assert_equal Pathname("/c/projects/-Users-dev-projects-webapp-jz-recurring-send-email/abc-123.jsonl"),
                 run.session_file("/c")
  end

  test "session_file domyślnie pyta o config, na którym run powstał" do
    run = reviews(:pr_review).claude_runs.create!(kind: "review", claude_config: "/c", session_id: "abc")
    assert_equal Pathname("/c/projects/-Users-dev-projects-webapp/abc.jsonl"), run.session_file
  end

  test "run bez session_id nie ma pliku sesji" do
    run = reviews(:pr_review).claude_runs.create!(kind: "review", claude_config: "/c")
    assert_nil run.session_file
    assert_not run.session_available_in?("/c")
  end

  test "session_available_in? widzi plik tylko w tym configu, w którym leży" do
    review = reviews(:pr_review)
    review.update!(worktree_path: "/wt")
    Dir.mktmpdir do |dir|
      run = review.claude_runs.create!(kind: "review", claude_config: "#{dir}/firm", session_id: "sess-1")
      FileUtils.mkdir_p("#{dir}/firm/projects/-wt")
      File.write("#{dir}/firm/projects/-wt/sess-1.jsonl", "{}")
      assert run.session_available_in?("#{dir}/firm")
      assert_not run.session_available_in?("#{dir}/pryw")
    end
  end

  # Opis zadania chodzi RÓWNOLEGLE z review, więc wspólny target broadcastu znaczyłby,
  # że obie sesje nadpisują sobie treść w losowej kolejności.
  test "should keep the progress of side cycles on its own channel" do
    review = reviews(:pr_review)

    %w[describe review followup compact].each do |kind|
      assert_equal "review", review.claude_runs.new(kind: kind).progress_scope, kind
    end
    %w[describe_task comment_task verify_fixes].each do |kind|
      assert_equal "side", review.claude_runs.new(kind: kind).progress_scope, kind
    end
  end

  test "should expose the latest side-cycle run separately from the review one" do
    review = reviews(:pr_review)
    review.claude_runs.create!(kind: "review", claude_config: "/x", status: "running")
    side = review.claude_runs.create!(kind: "describe_task", claude_config: "/x", status: "running")

    assert_equal side, review.side_claude_run
    assert_equal "review", review.running_review_run.kind, "postęp review nie może zniknąć pod cyklem pobocznym"
    assert_equal side, review.running_claude_run, "abort i guardy widzą każdą pracującą sesję"
  end
end
