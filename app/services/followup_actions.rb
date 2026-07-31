# Akcje na PR-ze po wysłanej decyzji: dodanie reviewera i/lub labelki. Wybory
# siedzą na review (zamrożone razem z decyzją), więc ponowienie po awarii używa
# dokładnie tego, co user widział. Każda akcja niezależnie — porażka jednej nie
# zatrzymuje drugiej i żadna nie tyka już wysłanej decyzji. Statusy zbieramy
# w jeden update!, żeby panel dostał jeden broadcast.
class FollowupActions
  ACTIONS = [
    { value: :followup_reviewer_login, status: :followup_reviewer_status, error: :followup_reviewer_error,
      run: ->(client, review, login) { client.add_reviewer(review.pr_url, login: login, repo_dir: review.workdir) } },
    { value: :followup_label_name, status: :followup_label_status, error: :followup_label_error,
      run: ->(client, review, name) { client.add_label(review.pr_url, name: name, repo_dir: review.workdir) } }
  ].freeze

  def self.call(review, client: GithubClient.new)
    new(review, client).call
  end

  def initialize(review, client)
    @review = review
    @client = client
  end

  def call
    changes = ACTIONS.each_with_object({}) do |action, acc|
      value = @review[action[:value]]
      next if value.blank? || @review[action[:status]] != "queued"

      acc.merge!(perform(action, value))
    end
    @review.update!(**changes) if changes.any?
  end

  private

  def perform(action, value)
    action[:run].call(@client, @review, value)
    { action[:status] => "sent", action[:error] => nil }
  rescue GithubClient::Error => e
    { action[:status] => "failed", action[:error] => e.message }
  end
end
