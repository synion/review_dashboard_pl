# Odświeża na review listę „kto już reviewował PR-a" (ostatni werdykt per osoba,
# bez mojego konta) — panel decyzji na tej podstawie podpowiada: nikt → dodaj
# reviewera, ktoś → dodaj label. Wynik żyje w kolumnie `pr_reviewers` (widok czyta
# `Review#pr_reviewers_list`), bo panel renderuje się przy każdym wejściu
# i broadcaście, a `gh pr view` to ~2 s spawnu. TTL pilnuje ReviewsController#show
# przez `Review#pr_reviewers_stale?` — lista reviewerów zmienia się rzadko.
class PrReviewers
  TTL = 10.minutes

  def self.refresh!(review, client: GithubClient.new)
    new(review, client).refresh!
  end

  def initialize(review, client)
    @review = review
    @client = client
  end

  def refresh!
    return if @review.pr_url.blank?

    @review.update!(pr_reviewers: fetch, pr_reviewers_checked_at: Time.current)
  rescue GithubClient::Error => e
    # Zostaje ostatni znany stan — podpowiedź w panelu nie jest warta wyjątku.
    Rails.logger.warn("PrReviewers review #{@review.id}: #{e.message}")
  end

  private

  def fetch
    me = viewer_login
    @client.pr_reviews(@review.pr_url, repo_dir: @review.workdir)
           .sort_by { |r| r["submittedAt"].to_s }
           .each_with_object({}) { |r, last| last[r.dig("author", "login")] = r["state"] }
           .reject { |login, _| login.blank? || login == me }
           .map { |login, state| { "login" => login, "state" => state } }
  end

  # Brak własnego loginu nie może wywalić listy — najwyżej pojawię się na niej sam.
  def viewer_login
    @client.viewer_login(repo_dir: @review.workdir)
  rescue GithubClient::Error
    nil
  end
end
