# Odtwarza z GitHuba listę PR-ów, na których czeka MOJE review — to samo, co widać
# w „Needs your review", plus PR-y, gdzie ktoś odezwał się po moim review.
#
# Dwa świadome wykluczenia: PR-y mojego autorstwa (swojego kodu nie recenzuję) i PR-y,
# w których po moim review nic się nie zmieniło (piłka jest u autora, nie u mnie).
# Wynik ląduje w tabeli, nie w Rails.cache: strona wejściowa musi pokazać kolejkę
# natychmiast po restarcie, a nie czekać na pierwsze odpytanie GitHuba.
class GithubInbox
  # Po tym czasie kolejka jest uznana za nieświeżą i wejście na stronę zleca
  # odświeżenie w tle. `gh search` to ~2 s — na render tego nie wpuszczamy.
  # Godzina zamiast minut: GitHub nie jest tu źródłem pilnych sygnałów, a każde
  # odpytanie to seria spawnów `gh`; kto chce świeżej, ma przycisk „Sprawdź teraz".
  STALE_AFTER = 1.hour
  # Luz dla harmonogramu, który tika równo co STALE_AFTER: odpytanie GitHuba kończy się
  # kilka sekund PO tiku, więc bez marginesu następny tik wypadałby o te sekundy za
  # wcześnie, uznawał kolejkę za świeżą i cadencja rozjeżdżałaby się na dwa interwały.
  TICK_GRACE = 1.minute

  def initialize(github: GithubClient.new, login: nil)
    @github = github
    @login = login
  end

  # Przepisuje kolejkę projektu w całości. Zwraca liczbę pozycji albo nil, gdy
  # projekt nie ma adresu repo (bez niego nie ma czego pytać).
  def refresh(project)
    repo = repo_slug(project)
    return nil unless repo

    @login ||= @github.viewer_login(repo_dir: project.repo_path)
    @project_prefix = project.task_url_prefix
    items = collect(project, repo)
    InboxItem.transaction do
      project.inbox_items.where.not(pr_number: items.map { |i| i[:pr_number] }).delete_all
      items.each { |attrs| upsert(project, attrs) }
      project.update_columns(inbox_checked_at: Time.current)
    end
    # Stąd, a nie z callbacku InboxItem: kolejkę przepisuje delete_all + upserty,
    # więc callbacki modelu i tak nie zobaczyłyby usunięć, a przy okazji strzelałyby
    # broadcastem raz na pozycję zamiast raz na odświeżenie.
    BroadcastDashboardJob.perform_later
    items.size
  rescue GithubClient::Error => e
    # Padnięte `gh search` NIE MOŻE wyczyścić kolejki: pusty wynik znaczyłby „nikt nie
    # czeka na Twoje review", a to jedyne miejsce, w którym ten sygnał jest widoczny.
    # Stempel przesuwamy, żeby nie odpytywać GitHuba przy każdym wejściu na stronę.
    Rails.logger.warn("GithubInbox #{project.name}: #{e.message}")
    project.update_columns(inbox_checked_at: Time.current)
    nil
  end

  private

  def collect(project, repo)
    requested = search(project, repo, "review-requested").map do |pr|
      item_for(pr, reason: "requested", signal_at: pr["updatedAt"], actor: author_of(pr),
                   body: task_body(project, pr))
    end
    # Prośba o review bije „odezwał się" — gdy PR łapie oba sygnały, zostaje ten pierwszy.
    seen = requested.map { |i| i[:pr_number] }
    commented = search(project, repo, "reviewed-by").reject { |pr| seen.include?(pr["number"]) }
                                                    .filter_map { |pr| commented_item(project, pr) }
    requested + commented
  end

  # `reviewed-by` zwraca każdy PR, który kiedykolwiek review'owałem — o piłce
  # decyduje dopiero porównanie ostatniego cudzego ruchu z moim ostatnim review.
  def commented_item(project, pr)
    activity = @github.pr_activity(pr["url"], repo_dir: project.repo_path)
    mine = timestamps(activity["reviews"], login: @login).max
    theirs = (timestamps(activity["reviews"], except: @login) +
              timestamps(activity["comments"], except: @login)).max
    return nil unless mine && theirs && theirs > mine

    item_for(pr, reason: "commented", signal_at: theirs, actor: last_actor(activity, theirs),
                 body: activity["body"])
  rescue GithubClient::Error => e
    # Jeden niedostępny PR nie może wywalić całej kolejki — reszta sygnałów jest wciąż warta pokazania.
    Rails.logger.warn("GithubInbox #{pr["url"]}: #{e.message}")
    nil
  end

  def item_for(pr, reason:, signal_at:, actor:, body: nil)
    { pr_number: pr["number"], title: pr["title"], url: pr["url"], author: author_of(pr),
      reason: reason, signal_at: signal_at, actor: actor,
      task_url: TaskLink.find(body, prefix: @project_prefix) }
  end

  # Opis PR-a pobieramy tylko dla prośb o review — przy „odezwał się" przychodzi
  # razem z aktywnością, a bez prefiksu trackera nie ma z niego czego wyciągać.
  def task_body(project, pr)
    return nil if project.task_url_prefix.blank?

    @github.pr_body(pr["url"], repo_dir: project.repo_path)
  rescue GithubClient::Error => e
    Rails.logger.warn("GithubInbox opis #{pr["url"]}: #{e.message}")
    nil
  end

  # Błąd leci wyżej (patrz rescue w #refresh) — inaczej „nie udało się zapytać"
  # byłoby nieodróżnialne od „nikt nie czeka".
  def search(project, repo, role)
    @github.search_prs(repo: repo, role: role, repo_dir: project.repo_path)
           .reject { |pr| author_of(pr) == @login }
  end

  def upsert(project, attrs)
    item = project.inbox_items.find_or_initialize_by(pr_number: attrs[:pr_number])
    item.update!(attrs)
  end

  def author_of(pr) = pr.dig("author", "login")

  def timestamps(events, login: nil, except: nil)
    Array(events).filter_map do |event|
      who = event.dig("author", "login")
      next if login && who != login
      next if except && who == except

      stamp = event["submittedAt"] || event["createdAt"]
      Time.zone.parse(stamp) if stamp
    end
  end

  def last_actor(activity, at)
    (Array(activity["reviews"]) + Array(activity["comments"]))
      .find { |event| Time.zone.parse((event["submittedAt"] || event["createdAt"]).to_s) == at }
      &.dig("author", "login")
  end

  def repo_slug(project) = project.github_slug
end
