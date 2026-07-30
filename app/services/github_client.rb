# Cienka nakładka na `gh` — auth bierze się z istniejącego logowania gh.
class GithubClient
  Error = Class.new(StandardError)

  VERDICT_FLAGS = { "approve" => "--approve", "reject" => "--request-changes", "comment" => "--comment" }.freeze
  VERDICT_EVENTS = { "approve" => "APPROVE", "reject" => "REQUEST_CHANGES", "comment" => "COMMENT" }.freeze
  PR_URL = %r{github\.com/(?<owner>[^/]+)/(?<repo>[^/]+)/pull/(?<number>\d+)}

  def initialize(runner: CommandRunner)
    @runner = runner
  end

  def pr_info(pr_url, repo_dir:)
    pr_view(pr_url, fields: "number,title,headRefName", repo_dir: repo_dir)
  end

  # Stan PR-a + kto jest poproszony o review — jedno `gh pr view` odpowiada na oba
  # pytania joba: czy PR jeszcze żyje i czy autor wrócił po ponowne review.
  def pr_review_state(pr_url, repo_dir:)
    pr_view(pr_url, fields: "reviewRequests,state", repo_dir: repo_dir)
  end

  def pr_diff(pr_url, repo_dir:)
    run!([ "gh", "pr", "diff", pr_url ], label: "gh pr diff", chdir: repo_dir).stdout
  end

  # Bez komentarzy zostajemy przy `gh pr review` — prostszej komendy, która nie
  # potrzebuje rozbierania URL-a na owner/repo/numer. Komentarze przy liniach umie
  # dopiero REST API, i to jednym requestem: werdykt, treść i wszystkie pinezki naraz.
  # Osobne requesty znaczyłyby tyle powiadomień dla autora, ile znalezisk.
  def submit_review(pr_url, verdict:, body:, repo_dir:, comments: [])
    return submit_simple_review(pr_url, verdict: verdict, body: body, repo_dir: repo_dir) if comments.blank?

    payload = { event: VERDICT_EVENTS.fetch(verdict), body: body, comments: comments }
    run!([ "gh", "api", reviews_endpoint(pr_url), "--method", "POST", "--input", "-" ],
         label: "gh api reviews", chdir: repo_dir, stdin_data: payload.to_json)
  end

  private

  def submit_simple_review(pr_url, verdict:, body:, repo_dir:)
    flag = VERDICT_FLAGS.fetch(verdict)
    run!([ "gh", "pr", "review", pr_url, flag, "--body-file", "-" ], label: "gh pr review", chdir: repo_dir, stdin_data: body)
  end

  def reviews_endpoint(pr_url)
    match = PR_URL.match(pr_url.to_s)
    raise Error, "Nie rozpoznaję linku do PR-a: #{pr_url}" unless match

    "repos/#{match[:owner]}/#{match[:repo]}/pulls/#{match[:number]}/reviews"
  end

  def pr_view(pr_url, fields:, repo_dir:)
    result = run!([ "gh", "pr", "view", pr_url, "--json", fields ], label: "gh pr view", chdir: repo_dir)
    JSON.parse(result.stdout)
  end

  # Odpala komendę gh i rzuca Error z jej stderr gdy się nie powiedzie.
  def run!(cmd, label:, **opts)
    result = @runner.run(cmd, **opts)
    raise Error, "#{label}: #{result.stderr}" unless result.success?

    result
  end
end
