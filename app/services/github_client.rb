# Cienka nakładka na `gh` — auth bierze się z istniejącego logowania gh.
class GithubClient
  Error = Class.new(StandardError)

  VERDICT_FLAGS = { "approve" => "--approve", "reject" => "--request-changes", "comment" => "--comment" }.freeze
  VERDICT_EVENTS = { "approve" => "APPROVE", "reject" => "REQUEST_CHANGES", "comment" => "COMMENT" }.freeze
  PR_URL = %r{github\.com/(?<owner>[^/]+)/(?<repo>[^/]+)/pull/(?<number>\d+)}

  # Jedyne miejsce rozbierające link do PR-a na nazwane grupy — walidacje Review
  # i endpoint niżej nie znają kształtu regexa, tylko wynik.
  def self.parse_pr_url(url)
    PR_URL.match(url.to_s)
  end

  # Kanoniczny identyfikator PR-a ("owner/repo#123", małymi literami): ten sam PR
  # wkleja się też jako .../pull/123/files albo z inną wielkością liter.
  # nil dla linku spoza wzorca.
  def self.pr_key(url)
    match = parse_pr_url(url)
    "#{match[:owner]}/#{match[:repo]}##{match[:number]}".downcase if match
  end

  def initialize(runner: CommandRunner)
    @runner = runner
  end

  # Mój login na GitHubie — po nim poznajemy, że PR jest CZYJŚ (swojego kodu nie
  # recenzuję) i że po moim review odezwał się ktoś inny. Pytamy o niego GITHUBA, nie
  # configu: filtry `@me` w `gh search` rozwiązują się do zalogowanego konta, a ręcznie
  # wpisany login potrafi się z nim rozjechać — i wtedy CUDZE PR-y wyglądają jak moje.
  # GITHUB_REVIEWER_LOGIN zostaje jako obejście, gdy `gh api user` jest niedostępny.
  def viewer_login(repo_dir:)
    @viewer_login ||= ENV["GITHUB_REVIEWER_LOGIN"].presence ||
                      Rails.cache.fetch("github_viewer_login", expires_in: 1.day) do
                        # Cache procesu, nie tylko instancji: login zalogowanego gh jest
                        # stały dla całej instalacji, a każdy klient tworzył nowy spawn.
                        run!([ "gh", "api", "user", "--jq", ".login" ], label: "gh api user", chdir: repo_dir).stdout.strip
                      end
  end

  # PR-y, w których jestem umoczony w danej roli: `review-requested` (GitHub prosi
  # o moje review) albo `reviewed-by` (już się wypowiedziałem). `--repo` zawęża do
  # repo projektu, żeby kolejka nie zaciągała całego GitHuba.
  def search_prs(repo:, role:, repo_dir:, limit: 40)
    result = run!([ "gh", "search", "prs", "--repo", repo, "--state", "open",
                    "--#{role}", "@me", "--limit", limit.to_s,
                    "--json", "number,title,url,author,updatedAt" ],
                  label: "gh search prs --#{role}", chdir: repo_dir)
    JSON.parse(result.stdout)
  end

  # Cała aktywność ludzi na PR-ze: po niej liczymy, czy ktoś odezwał się PO moim
  # ostatnim review. Samo `updatedAt` nie wystarcza — podnosi je też mój własny
  # komentarz i każdy push autora.
  # `body` jedzie tu z aktywnością, żeby nie robić drugiego zapytania o ten sam PR —
  # z opisu wyciągamy link do zadania (patrz TaskLink).
  def pr_activity(pr_url, repo_dir:)
    pr_view(pr_url, fields: "state,author,reviews,comments,body", repo_dir: repo_dir)
  end

  def pr_body(pr_url, repo_dir:)
    pr_view(pr_url, fields: "body", repo_dir: repo_dir)["body"]
  end

  def pr_info(pr_url, repo_dir:)
    pr_view(pr_url, fields: "number,title,headRefName,body", repo_dir: repo_dir)
  end

  # Stan PR-a + kto jest poproszony o review — jedno `gh pr view` odpowiada na oba
  # pytania joba: czy PR jeszcze żyje i czy autor wrócił po ponowne review.
  def pr_review_state(pr_url, repo_dir:)
    pr_view(pr_url, fields: "reviewRequests,state", repo_dir: repo_dir)
  end

  # SHA głowy PR-a — punkt odniesienia weryfikacji poprawek. Zapisujemy go przy
  # decyzji, bo tylko wtedy wiemy, na jaki kod patrzył człowiek.
  def pr_head_sha(pr_url, repo_dir:)
    pr_view(pr_url, fields: "headRefOid", repo_dir: repo_dir)["headRefOid"]
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
    run!([ "gh", "api", pr_endpoint(pr_url, "pulls", "reviews"), "--method", "POST", "--input", "-" ],
         label: "gh api reviews", chdir: repo_dir, stdin_data: payload.to_json)
  end

  # Loginy osób z prawem zapisu do repo — kandydaci na drugiego reviewera.
  # jq od razu wyłuskuje loginy (linia na osobę), więc nie ma czego parsować.
  def collaborators(repo:, repo_dir:)
    run!([ "gh", "api", "repos/#{repo}/collaborators", "--paginate", "--jq", ".[].login" ],
         label: "gh api collaborators", chdir: repo_dir).stdout.split("\n")
  end

  # Nazwy labelek zdefiniowanych w repo — do wyboru „label po decyzji". Limit 200
  # zamiast domyślnych 30: repo z większą liczbą labeli ucinałoby listę po cichu.
  def labels(repo_dir:)
    run!([ "gh", "label", "list", "--json", "name", "--jq", ".[].name", "--limit", "200" ],
         label: "gh label list", chdir: repo_dir).stdout.split("\n")
  end

  # Same reviews, bez comments/body — dla listy „kto reviewował" pr_activity
  # ściągałoby gadatliwe pola, których nikt tu nie czyta.
  def pr_reviews(pr_url, repo_dir:)
    pr_view(pr_url, fields: "reviews", repo_dir: repo_dir)["reviews"].to_a
  end

  # Obie akcje idą przez REST, a nie przez `gh pr edit`: ta komenda dociąga w swoim
  # zapytaniu GraphQL pole `projectCards` (Projects classic), a GitHub odpowiada na nie
  # twardym błędem o wycofaniu — edycja nie dochodziła do skutku niezależnie od tego,
  # co zmieniała. REST-owe endpointy nie znają Projects i robią dokładnie jedną rzecz.
  def add_reviewer(pr_url, login:, repo_dir:)
    run!([ "gh", "api", pr_endpoint(pr_url, "pulls", "requested_reviewers"), "--method", "POST", "--input", "-" ],
         label: "gh api requested_reviewers", chdir: repo_dir, stdin_data: { reviewers: [ login ] }.to_json)
  end

  # Labelki wiszą pod zasobem issue — PR-y dzielą z issues numerację i ten endpoint.
  def add_label(pr_url, name:, repo_dir:)
    run!([ "gh", "api", pr_endpoint(pr_url, "issues", "labels"), "--method", "POST", "--input", "-" ],
         label: "gh api labels", chdir: repo_dir, stdin_data: { labels: [ name ] }.to_json)
  end

  private

  def submit_simple_review(pr_url, verdict:, body:, repo_dir:)
    flag = VERDICT_FLAGS.fetch(verdict)
    run!([ "gh", "pr", "review", pr_url, flag, "--body-file", "-" ], label: "gh pr review", chdir: repo_dir, stdin_data: body)
  end

  # Ścieżka REST-owa dla PR-a: `kind` to "pulls" albo "issues" (część zasobów PR-a
  # GitHub trzyma pod issue o tym samym numerze), `path` to końcówka endpointu.
  def pr_endpoint(pr_url, kind, path)
    match = self.class.parse_pr_url(pr_url)
    raise Error, "Nie rozpoznaję linku do PR-a: #{pr_url}" unless match

    "repos/#{match[:owner]}/#{match[:repo]}/#{kind}/#{match[:number]}/#{path}"
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
