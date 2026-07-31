# Odświeża w tle listę „kto reviewował PR-a" (cache na review). Zlecany przez
# ReviewsController#show, gdy cache się zestarzeje — zapis cache broadcastuje
# review, więc panel decyzji sam się przerysuje. Awarie gh łyka PrReviewers.
class RefreshPrReviewersJob < ApplicationJob
  queue_as :default

  def perform(review)
    PrReviewers.refresh!(review)
  end
end
