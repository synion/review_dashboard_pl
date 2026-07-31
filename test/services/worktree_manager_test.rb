require "test_helper"

class WorktreeManagerTest < ActiveSupport::TestCase
  class FakeRunner
    attr_reader :calls

    def initialize(results)
      @results = results
      @calls = []
    end

    def run(cmd, env: {}, chdir:, timeout: 600, stdin_data: nil)
      @calls << { cmd: cmd, chdir: chdir, timeout: timeout }
      @results.shift
    end
  end

  WORKTREE_LIST = <<~OUT
    worktree /Users/dev/projects/webapp
    branch refs/heads/master

    worktree /Users/dev/projects/webapp-sl-fix-vat
    branch refs/heads/sl-fix-vat
  OUT

  def ok(stdout = "")
    CommandRunner::Result.new(exit_code: 0, stdout: stdout, stderr: "", timed_out: false)
  end

  test "ensure_for_branch zwraca istniejący worktree" do
    fake = FakeRunner.new([ ok(WORKTREE_LIST) ])
    path = WorktreeManager.new(projects(:webapp), runner: fake).ensure_for_branch("sl-fix-vat")
    assert_equal "/Users/dev/projects/webapp-sl-fix-vat", path
    assert_equal 1, fake.calls.size
  end

  test "ensure_for_branch tworzy worktree komendą projektu gdy brak" do
    fake = FakeRunner.new([ ok(""), ok(""), ok(WORKTREE_LIST) ])
    path = WorktreeManager.new(projects(:webapp), runner: fake).ensure_for_branch("sl-fix-vat")
    assert_equal "/Users/dev/projects/webapp-sl-fix-vat", path
    create_call = fake.calls[1]
    assert_equal [ "/bin/zsh", "-c", "bin/worktree-docker sl-fix-vat" ], create_call[:cmd]
    assert_equal "/Users/dev/projects/webapp", create_call[:chdir]
    assert_equal 1800, create_call[:timeout]
  end

  test "ensure_for_branch rzuca Error gdy tworzenie padło" do
    fake = FakeRunner.new([ ok(""), CommandRunner::Result.new(exit_code: 1, stdout: "", stderr: "brak dysku", timed_out: false) ])
    error = assert_raises(WorktreeManager::Error) { WorktreeManager.new(projects(:webapp), runner: fake).ensure_for_branch("sl-fix-vat") }
    assert_includes error.message, "brak dysku"
  end

  test "remove odpala komendę usuwania worktree projektu" do
    fake = FakeRunner.new([ ok("") ])
    WorktreeManager.new(projects(:webapp), runner: fake).remove("sl-fix-vat")
    assert_equal [ { cmd: [ "/bin/zsh", "-c", "bin/worktree-docker -d sl-fix-vat --force" ], chdir: "/Users/dev/projects/webapp", timeout: 600 } ], fake.calls
  end

  test "checkout_pr odpala gh pr checkout w worktree" do
    fake = FakeRunner.new([ ok("") ])
    WorktreeManager.new(projects(:webapp), runner: fake).checkout_pr("/wt", "https://github.com/acme/webapp/pull/1")
    assert_equal [ { cmd: [ "gh", "pr", "checkout", "https://github.com/acme/webapp/pull/1" ], chdir: "/wt", timeout: 600 } ], fake.calls
  end

  test "should list worktree branches without the main checkout and detached heads" do
    listing = <<~OUT
      worktree /Users/dev/projects/webapp
      branch refs/heads/master

      worktree /Users/dev/projects/webapp-zzz-later
      branch refs/heads/zzz-later

      worktree /Users/dev/projects/webapp-detached
      HEAD abc123
      detached

      worktree /Users/dev/projects/webapp-sl-fix-vat
      branch refs/heads/sl-fix-vat
    OUT
    fake = FakeRunner.new([ ok(listing) ])

    branches = WorktreeManager.new(projects(:webapp), runner: fake).existing_branches

    assert_equal %w[sl-fix-vat zzz-later], branches
  end

  test "should degrade branch suggestions to an empty list when git fails" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 128, stdout: "", stderr: "not a git repo", timed_out: false) ])

    assert_equal [], WorktreeManager.new(projects(:webapp), runner: fake).existing_branches
  end
end
