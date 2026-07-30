require "test_helper"

class GithubClientTest < ActiveSupport::TestCase
  class FakeRunner
    attr_reader :calls

    def initialize(results)
      @results = results
      @calls = []
    end

    def run(cmd, env: {}, chdir:, timeout: 600, stdin_data: nil)
      @calls << { cmd: cmd, chdir: chdir, stdin_data: stdin_data }
      @results.shift
    end
  end

  PR_URL = "https://github.com/acme/webapp/pull/1234"

  test "pr_info parsuje JSON z gh" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: { number: 1234, title: "Fix VAT", headRefName: "sl-fix-vat" }.to_json, stderr: "", timed_out: false) ])
    info = GithubClient.new(runner: fake).pr_info(PR_URL, repo_dir: "/repo")
    assert_equal({ "number" => 1234, "title" => "Fix VAT", "headRefName" => "sl-fix-vat" }, info)
    assert_equal [ { cmd: [ "gh", "pr", "view", PR_URL, "--json", "number,title,headRefName" ], chdir: "/repo", stdin_data: nil } ], fake.calls
  end

  test "pr_info rzuca Error z treścią stderr" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 1, stdout: "", stderr: "no pull requests found", timed_out: false) ])
    error = assert_raises(GithubClient::Error) { GithubClient.new(runner: fake).pr_info(PR_URL, repo_dir: "/repo") }
    assert_includes error.message, "no pull requests found"
  end

  test "pr_review_state pobiera reviewRequests i state" do
    payload = { reviewRequests: [ { login: "synion" } ], state: "OPEN" }.to_json
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: payload, stderr: "", timed_out: false) ])
    info = GithubClient.new(runner: fake).pr_review_state(PR_URL, repo_dir: "/repo")
    assert_equal({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "OPEN" }, info)
    assert_equal [ { cmd: [ "gh", "pr", "view", PR_URL, "--json", "reviewRequests,state" ], chdir: "/repo", stdin_data: nil } ], fake.calls
  end

  test "submit_review mapuje verdict na flagę gh i wysyła body przez stdin" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "", stderr: "", timed_out: false) ])
    GithubClient.new(runner: fake).submit_review(PR_URL, verdict: "reject", body: "Uwagi", repo_dir: "/repo")
    assert_equal [ { cmd: [ "gh", "pr", "review", PR_URL, "--request-changes", "--body-file", "-" ], chdir: "/repo", stdin_data: "Uwagi" } ], fake.calls
  end

  test "pr_diff zwraca surowy diff" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "diff --git a/x b/x\n", stderr: "", timed_out: false) ])
    assert_equal "diff --git a/x b/x\n", GithubClient.new(runner: fake).pr_diff(PR_URL, repo_dir: "/repo")
    assert_equal [ { cmd: [ "gh", "pr", "diff", PR_URL ], chdir: "/repo", stdin_data: nil } ], fake.calls
  end

  test "submit_review z komentarzami idzie przez gh api — jeden request z werdyktem i pinezkami" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "{}", stderr: "", timed_out: false) ])
    comments = [ { path: "app/x.rb", line: 5, side: "RIGHT", body: "uwaga" } ]
    GithubClient.new(runner: fake).submit_review(PR_URL, verdict: "approve", body: "LGTM", repo_dir: "/repo", comments: comments)

    call = fake.calls.sole
    assert_equal [ "gh", "api", "repos/acme/webapp/pulls/1234/reviews", "--method", "POST", "--input", "-" ], call[:cmd]
    assert_equal({ "event" => "APPROVE", "body" => "LGTM",
                   "comments" => [ { "path" => "app/x.rb", "line" => 5, "side" => "RIGHT", "body" => "uwaga" } ] },
                 JSON.parse(call[:stdin_data]))
  end

  test "submit_review z komentarzami mapuje verdict na event GitHuba" do
    %w[approve reject comment].zip(%w[APPROVE REQUEST_CHANGES COMMENT]).each do |verdict, event|
      fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "{}", stderr: "", timed_out: false) ])
      GithubClient.new(runner: fake).submit_review(PR_URL, verdict: verdict, body: "x", repo_dir: "/repo",
                                                   comments: [ { path: "a", line: 1 } ])
      assert_equal event, JSON.parse(fake.calls.sole[:stdin_data])["event"]
    end
  end

  test "pusta lista komentarzy zostaje na starej ścieżce gh pr review" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "", stderr: "", timed_out: false) ])
    GithubClient.new(runner: fake).submit_review(PR_URL, verdict: "comment", body: "x", repo_dir: "/repo", comments: [])
    assert_equal "gh pr review", fake.calls.sole[:cmd].first(3).join(" ")
  end

  test "link do PR-a nie do rozpoznania — błąd zamiast requestu w próżnię" do
    fake = FakeRunner.new([])
    error = assert_raises(GithubClient::Error) do
      GithubClient.new(runner: fake).submit_review("https://example.com/foo", verdict: "approve", body: "x",
                                                   repo_dir: "/repo", comments: [ { path: "a", line: 1 } ])
    end
    assert_includes error.message, "https://example.com/foo"
    assert_empty fake.calls
  end
end
