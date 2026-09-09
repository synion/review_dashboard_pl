# Pyta GitHuba o stan PR-a review, które czeka na człowieka: czy autor poprosił mnie
# o ponowne review (waiting_review, tylko po decyzji), czy PR już wjechał / został
# porzucony (stan końcowy — na każdym etapie, patrz Review::CHECKABLE_STATUSES).
# Wykrycie tylko oznacza — nie odpala sesji, nie rusza findings.
class CheckReviewRequestJob < ApplicationJob
  queue_as :default

  # Stan PR-a z GitHuba → końcowy status review. Zamknięty PR nie potrzebuje żadnej
  # akcji, a ten status wypada z Review.due_for_github_check — więc to zarazem
  # ostatnie pytanie o ten PR.
  FINAL_STATES = { "MERGED" => "merged", "CLOSED" => "closed" }.freeze
  # Automatyczny followup (płatna sesja) tylko dla świeżych decyzji. Starsze podważenia
  # dostają status i baner, a sesję odpala człowiek - inaczej pierwsze sprawdzenie po
  # wdrożeniu detekcji odpaliło naraz pięć sesji do PR-ów sprzed miesiąca.
  AUTO_FOLLOWUP_WINDOW = 14.days

  def perform(review, github: GithubClient.new)
    # Status mógł się zmienić między kolejkowaniem a startem (np. user odpalił followup).
    return unless Review::CHECKABLE_STATUSES.include?(review.status) && review.github_actions_available?

    info = pr_review_state(review, github)

    # Kiedy na PR-ze ostatnio cokolwiek się działo — do kolumny „Ruch na PR"
    # na liście. `compact`: padnięty gh daje puste info, a brak klucza nie
    # nadpisze nilem ostatniej znanej daty — stara jest więcej warta niż żadna.
    stamps = { github_checked_at: Time.current, pr_activity_at: info["updatedAt"] }.compact

    if (final_status = FINAL_STATES[info["state"]])
      review.update!(status: final_status, **stamps)
    elsif review.status == "decided" && rerequested?(info, github, review)
      review.update!(status: "waiting_review", **stamps)
    elsif review.status == "decided" && (challenge = challenge_for(review, info, github))
      # Podważona decyzja: sesja od razu konfrontuje mój wniosek z cudzym, zamiast
      # czekać, aż user wklei cudze uwagi ręcznie (review 116: pięć dni).
      challenge!(review, challenge, stamps)
    else
      # Sam stempel przez update_columns — rutynowe „nic się nie zmieniło" nie ma
      # co odpalać walidacji ani broadcastów panelu.
      review.update_columns(stamps)
    end
  end

  private

  def pr_review_state(review, github)
    github.pr_review_state(review.pr_url, repo_dir: review.workdir)
  rescue GithubClient::Error => e
    # Stempel i tak zapisujemy — inaczej padający gh byłby odpytywany co wejście na listę.
    Rails.logger.warn("CheckReviewRequestJob review #{review.id}: #{e.message}")
    {}
  end

  # Tylko approve da się podważyć: comment i reject same mówią „nie mergować”.
  # Najpierw PR (tanie, dane już mamy), potem tracker (osobny request, tylko z integracją).
  def challenge_for(review, info, github)
    return unless review.decision == "approve" && review.decided_at.present? && info["state"] == "OPEN"

    pr_challenge(review, info, github) || task_challenge(review)
  end

  # Cudze CHANGES_REQUESTED złożone po mojej decyzji - z tego samego `gh pr view`,
  # które dało stan PR-a (pole `reviews`), bez drugiego spawnu.
  def pr_challenge(review, info, github)
    me = github.viewer_login(repo_dir: review.workdir)
    challenger = Array(info["reviews"]).find do |other|
      login = other.dig("author", "login")
      other["state"] == "CHANGES_REQUESTED" && login.present? && login != me &&
        (at = Time.zone.parse(other["submittedAt"].to_s)) && at > review.decided_at
    end
    { "source" => "pr", "by" => challenger.dig("author", "login") } if challenger
  end

  # API trackera nie zwraca komentarzy per zadanie, ale zwraca ich liczbę - wzrost
  # od chwili decyzji wystarcza za sygnał; treść przeczyta sesja followupu.
  def task_challenge(review)
    baseline = review.decision_task_comments_count
    return if baseline.nil?

    count = review.task_comments_count_now
    { "source" => "task", "count" => count } if count && count > baseline
  end

  def challenge!(review, challenge, stamps)
    attrs = { status: "challenged", challenge: challenge, **stamps }
    # Nowe komentarze w zadaniu mają wejść do „Ustalenia z komentarzy” - followup
    # i bramka zgodności czytają opis, nie tracker.
    attrs[:task_description_status] = "queued" if challenge["source"] == "task"
    review.update!(attrs)
    return if review.decided_at < AUTO_FOLLOWUP_WINDOW.ago

    DescribeTaskJob.perform_later(review) if challenge["source"] == "task"
    FollowupReviewJob.perform_later(review, Review.challenge_message(review, challenge))
  end

  def rerequested?(info, github, review)
    return false unless info["state"] == "OPEN"

    login = github.viewer_login(repo_dir: review.workdir)
    return false unless Array(info["reviewRequests"]).any? { |request| request["login"] == login }

    # Akcja „reviewer" po decyzji potrafi dodać własny login — taki request wisi
    # od chwili decyzji aż do następnego review, więc jego obecność nie mówi nic
    # o autorze. Prawdziwy ruch autora widać wtedy w „Ruch na PR" (pr_activity_at).
    !(review.followup_reviewer_status == "sent" && review.followup_reviewer_login == login)
  end
end
