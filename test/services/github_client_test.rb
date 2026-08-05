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
    assert_equal [ { cmd: [ "gh", "pr", "view", PR_URL, "--json", "number,title,headRefName,body" ], chdir: "/repo", stdin_data: nil } ], fake.calls
  end

  test "pr_info rzuca Error z treścią stderr" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 1, stdout: "", stderr: "no pull requests found", timed_out: false) ])
    error = assert_raises(GithubClient::Error) { GithubClient.new(runner: fake).pr_info(PR_URL, repo_dir: "/repo") }
    assert_includes error.message, "no pull requests found"
  end

  test "pr_review_state pobiera reviewRequests, state i updatedAt" do
    payload = { reviewRequests: [ { login: "synion" } ], state: "OPEN", updatedAt: "2026-08-04T10:00:00Z" }.to_json
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: payload, stderr: "", timed_out: false) ])
    info = GithubClient.new(runner: fake).pr_review_state(PR_URL, repo_dir: "/repo")
    assert_equal({ "reviewRequests" => [ { "login" => "synion" } ], "state" => "OPEN",
                   "updatedAt" => "2026-08-04T10:00:00Z" }, info)
    assert_equal [ { cmd: [ "gh", "pr", "view", PR_URL, "--json", "reviewRequests,state,updatedAt" ], chdir: "/repo", stdin_data: nil } ], fake.calls
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

  test "should ask GitHub who I am and cache the answer" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "wilkszymon\n", stderr: "", timed_out: false) ])
    client = GithubClient.new(runner: fake)

    assert_equal "wilkszymon", client.viewer_login(repo_dir: "/repo")
    assert_equal "wilkszymon", client.viewer_login(repo_dir: "/repo"), "drugie pytanie idzie z pamięci"
    assert_equal [ [ "gh", "api", "user", "--jq", ".login" ] ], fake.calls.map { |call| call[:cmd] }
  end

  # Obejście na wypadek niedostępnego `gh api user` — a zarazem jedyny sposób
  # przetestowania tej ścieżki bez sieci.
  test "should prefer the configured login over asking GitHub" do
    fake = FakeRunner.new([])
    original = ENV["GITHUB_REVIEWER_LOGIN"]
    ENV["GITHUB_REVIEWER_LOGIN"] = "z-configu"

    assert_equal "z-configu", GithubClient.new(runner: fake).viewer_login(repo_dir: "/repo")
    assert_empty fake.calls
  ensure
    ENV["GITHUB_REVIEWER_LOGIN"] = original
  end

  test "should search PRs by my role in a single repo" do
    payload = [ { "number" => 7, "title" => "t", "url" => "u", "author" => { "login" => "kolega" },
                  "updatedAt" => "2026-07-30T08:00:00Z" } ]
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: payload.to_json, stderr: "", timed_out: false) ])

    result = GithubClient.new(runner: fake).search_prs(repo: "acme/webapp", role: "review-requested", repo_dir: "/repo")

    assert_equal payload, result
    assert_equal [ "gh", "search", "prs", "--repo", "acme/webapp", "--state", "open",
                   "--review-requested", "@me", "--limit", "40",
                   "--json", "number,title,url,author,updatedAt" ], fake.calls.sole[:cmd]
  end

  test "should ask for the whole human activity on a PR" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "{}", stderr: "", timed_out: false) ])
    GithubClient.new(runner: fake).pr_activity(PR_URL, repo_dir: "/repo")
    assert_equal [ "gh", "pr", "view", PR_URL, "--json", "state,author,reviews,comments,body" ], fake.calls.sole[:cmd]
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

  test "should read the head sha of a PR" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: { headRefOid: "abc123" }.to_json, stderr: "", timed_out: false) ])

    assert_equal "abc123", GithubClient.new(runner: fake).pr_head_sha(PR_URL, repo_dir: "/repo")
    assert_equal [ "gh", "pr", "view", PR_URL, "--json", "headRefOid" ], fake.calls.sole[:cmd]
  end

  test "collaborators zwraca loginy z paginowanego gh api" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "anna\njan\n", stderr: "", timed_out: false) ])
    logins = GithubClient.new(runner: fake).collaborators(repo: "acme/webapp", repo_dir: "/repo")

    assert_equal %w[anna jan], logins
    assert_equal [ "gh", "api", "repos/acme/webapp/collaborators", "--paginate", "--jq", ".[].login" ],
                 fake.calls.sole[:cmd]
  end

  test "labels zwraca nazwy labeli repo" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "bug\nwip\n", stderr: "", timed_out: false) ])
    labels = GithubClient.new(runner: fake).labels(repo_dir: "/repo")

    assert_equal %w[bug wip], labels
    assert_equal [ "gh", "label", "list", "--json", "name", "--jq", ".[].name", "--limit", "200" ], fake.calls.sole[:cmd]
  end

  test "pr_reviews pobiera tylko pole reviews" do
    payload = { reviews: [ { author: { login: "anna" }, state: "APPROVED" } ] }.to_json
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: payload, stderr: "", timed_out: false) ])
    reviews = GithubClient.new(runner: fake).pr_reviews(PR_URL, repo_dir: "/repo")

    assert_equal [ { "author" => { "login" => "anna" }, "state" => "APPROVED" } ], reviews
    assert_equal [ "gh", "pr", "view", PR_URL, "--json", "reviews" ], fake.calls.sole[:cmd]
  end

  test "add_reviewer prosi o review przez REST, bez gh pr edit" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "", stderr: "", timed_out: false) ])
    GithubClient.new(runner: fake).add_reviewer(PR_URL, login: "anna", repo_dir: "/repo")

    call = fake.calls.sole
    assert_equal [ "gh", "api", "repos/acme/webapp/pulls/1234/requested_reviewers", "--method", "POST", "--input", "-" ],
                 call[:cmd]
    assert_equal({ "reviewers" => [ "anna" ] }, JSON.parse(call[:stdin_data]))
  end

  test "add_label dopina labelkę przez REST endpoint issue" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 0, stdout: "", stderr: "", timed_out: false) ])
    GithubClient.new(runner: fake).add_label(PR_URL, name: "po reviews", repo_dir: "/repo")

    call = fake.calls.sole
    assert_equal [ "gh", "api", "repos/acme/webapp/issues/1234/labels", "--method", "POST", "--input", "-" ], call[:cmd]
    assert_equal({ "labels" => [ "po reviews" ] }, JSON.parse(call[:stdin_data]))
  end

  test "add_reviewer rzuca Error ze stderr gdy gh odmawia" do
    fake = FakeRunner.new([ CommandRunner::Result.new(exit_code: 1, stdout: "", stderr: "not a collaborator", timed_out: false) ])
    error = assert_raises(GithubClient::Error) do
      GithubClient.new(runner: fake).add_reviewer(PR_URL, login: "obcy", repo_dir: "/repo")
    end
    assert_includes error.message, "not a collaborator"
  end
end
