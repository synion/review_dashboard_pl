# Sprawdza, co autor zrobił z moimi uwagami po wysłaniu decyzji: dla każdego
# znaleziska osobno mówi „wdrożone / zignorowane / niejasne" wraz z uzasadnieniem.
#
# Osobna, krótka sesja, a nie followup: followup robi PONOWNE review (nadpisuje
# result.json i cofa review do „reviewed"), a tu chodzi wyłącznie o odpowiedź na
# pytanie „czy moje uwagi zostały zaadresowane" — status review zostaje nietknięty.
class VerifyFixesJob < ApplicationJob
  queue_as :default

  def perform(review, github: GithubClient.new, session_factory: default_session_factory)
    return unless review.fixes_verifiable?

    discussion = PrDiscussion.for(review, client: github)
    head = current_head(review, github)
    # Nic się nie wydarzyło od decyzji: sesja nie miałaby czego czytać, a kosztowałaby
    # tyle samo. Stempel przesuwamy, żeby UI mógł napisać, kiedy sprawdzaliśmy.
    return review.update!(fixes_checked_at: Time.current) if nothing_new?(review, head, discussion)

    run = review.claude_runs.create!(kind: "verify_fixes", claude_config: review.effective_claude_config)
    session_factory.call(run).call(PromptBuilder.verify_fixes(review, discussion: discussion))
    FixVerificationImporter.call(review)
  rescue StandardError => e
    # Świadomie NIE wołamy review.fail!: weryfikacja poprawek jest cyklem pobocznym,
    # a jej porażka nie może zamazać wysłanej decyzji ani znalezisk (tak samo jak
    # przy opisie zadania i komentarzu do zadania).
    Rails.logger.warn("VerifyFixesJob review #{review.id}: #{e.message}")
  end

  private

  # Sam niezmieniony SHA już nie wystarcza, żeby odpuścić sesję: autor bywa, że nie
  # rusza kodu, tylko odpisuje pod pinezką („zostawiam świadomie, bo…") — a to jest
  # dokładnie ten materiał, po który tu przychodzimy. Brak dyskusji (padnięty gh)
  # zachowuje się jak dawniej: liczy się tylko SHA.
  def nothing_new?(review, head, discussion)
    head.present? && head == review.decision_head_sha &&
      discussion&.replies_after(review.decided_at).blank?
  end

  # Brak SHA (padnięty gh) traktujemy jak „nie wiem" i pytamy sesję — lepiej zapłacić
  # za jedną sesję niż wmówić userowi, że autor nic nie zmienił.
  def current_head(review, github)
    github.pr_head_sha(review.pr_url, repo_dir: review.workdir)
  rescue GithubClient::Error => e
    Rails.logger.warn("VerifyFixesJob review #{review.id}: #{e.message}")
    nil
  end
end
