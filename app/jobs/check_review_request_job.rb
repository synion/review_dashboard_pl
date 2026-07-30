# Pyta GitHuba o stan PR-a po decyzji: czy autor poprosił mnie o ponowne review
# (waiting_review), czy PR już wjechał / został porzucony (stan końcowy).
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

    if (final_status = FINAL_STATES[info["state"]])
      review.update!(status: final_status, github_checked_at: Time.current)
    elsif review.status == "decided" && rerequested?(info)
      review.update!(status: "waiting_review", github_checked_at: Time.current)
    else
      # Sam stempel przez update_columns — rutynowe „nic się nie zmieniło" nie ma
      # co odpalać walidacji ani broadcastów panelu.
      review.update_columns(github_checked_at: Time.current)
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

  def rerequested?(info)
    info["state"] == "OPEN" && Array(info["reviewRequests"]).any? { |r| r["login"] == reviewer_login }
  end

  def reviewer_login
    ENV.fetch("GITHUB_REVIEWER_LOGIN", "synion")
  end
end
