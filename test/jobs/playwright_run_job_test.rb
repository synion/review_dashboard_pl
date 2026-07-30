require "test_helper"

class PlaywrightRunJobTest < ActiveSupport::TestCase
  class FakeRunner
    attr_reader :calls

    def initialize(exit_code:)
      @exit_code = exit_code
      @calls = []
    end

    def run(cmd, env: {}, chdir:, timeout: 600, stdin_data: nil)
      @calls << { cmd: cmd, env: env, chdir: chdir, timeout: timeout }
      CommandRunner::Result.new(exit_code: @exit_code, stdout: "1 passed", stderr: "", timed_out: false)
    end
  end

  setup do
    @review = reviews(:pr_review)
    @review.update!(worktree_path: "/wt", playwright_command: "npx playwright test tmp/rev.spec.js")
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  test "headless: HEADLESS=1, sukces daje passed" do
    run = @review.playwright_runs.create!(mode: "headless", status: "running")
    fake = FakeRunner.new(exit_code: 0)
    PlaywrightRunJob.perform_now(run, runner: fake)
    run.reload
    assert_equal({ status: "passed", exit_code: 0 }, { status: run.status, exit_code: run.exit_code })
    assert_equal [ { cmd: [ "/bin/zsh", "-c", "npx playwright test tmp/rev.spec.js" ], env: { "HEADLESS" => "1" }, chdir: "/wt", timeout: 1800 } ], fake.calls
    assert_includes File.read(run.output_path), "1 passed"
  end

  test "wyjątek w jobie ustawia failed z komunikatem w logu zamiast wiecznego running" do
    run = @review.playwright_runs.create!(mode: "headless", status: "running")
    failing = Object.new.tap { |o| o.define_singleton_method(:run) { |*_a, **_kw| raise Errno::ENOENT, "brak katalogu" } }
    PlaywrightRunJob.perform_now(run, runner: failing)
    run.reload
    assert_equal "failed", run.status
    assert_includes File.read(run.output_path), "Błąd uruchomienia"
  end

  test "bez worktree_path używa repo projektu jako workdir" do
    @review.update!(worktree_path: nil)
    run = @review.playwright_runs.create!(mode: "headless", status: "running")
    fake = FakeRunner.new(exit_code: 0)
    PlaywrightRunJob.perform_now(run, runner: fake)
    assert_equal "/Users/dev/projects/webapp", fake.calls.first[:chdir]
  end

  test "headed: bez HEADLESS, fail daje failed" do
    run = @review.playwright_runs.create!(mode: "headed", status: "running")
    fake = FakeRunner.new(exit_code: 1)
    PlaywrightRunJob.perform_now(run, runner: fake)
    run.reload
    assert_equal({ status: "failed", exit_code: 1, env: {} }, { status: run.status, exit_code: run.exit_code, env: fake.calls.first[:env] })
  end
end
