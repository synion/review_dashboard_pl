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
