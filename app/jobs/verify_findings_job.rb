# Weryfikuje zasadność znalezisk ŚWIEŻĄ sesją (bez --resume): sesja, która
# uwagi wymyśliła, broni własnych ustaleń — bezstronny werdykt wymaga braku
# jej kontekstu. Nie rusza statusu review ani treści znalezisk, tylko dokłada
# im verdict/verdict_note.
class VerifyFindingsJob < ApplicationJob
  queue_as :default

  # model/effort/claude_config nadpisują ustawienia review tylko dla tej jednej
  # sesji — druga opinia często ma iść mocniejszym modelem, a bywa odpalana
  # z drugiego konta (limity). Sesja jest świeża, więc zmiana konta nie wymaga
  # migracji plików sesji jak przy switch_config.
  def perform(review, model: nil, effort: nil, claude_config: nil, session_factory: default_session_factory)
    return unless review.findings_verifiable?

    run = review.claude_runs.create!(kind: "verify_findings",
                                     claude_config: claude_config.presence || review.effective_claude_config,
                                     model: model, effort: effort)
    session_factory.call(run).call(PromptBuilder.verify_findings(review))
    FindingVerificationImporter.call(review)
  rescue StandardError => e
    # Świadomie NIE wołamy review.fail!: weryfikacja jest cyklem pobocznym i jej
    # porażka nie może zamazać wyniku review (jak przy verify_fixes).
    Rails.logger.warn("VerifyFindingsJob review #{review.id}: #{e.message}")
  end
end
