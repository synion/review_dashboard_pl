# Zapisuje przy review wynik pukania do jego środowiska dev (WorktreeHealth), żeby
# „Apka z tego brancha" nie okazała się piątką dopiero w chwili, gdy chcesz coś kliknąć.
#
# Osobny job, a nie krok w DescribeReviewJob: pierwsze żądanie do puma-dev bootuje
# Railsy i potrafi trwać minutę — opis review nie ma na co czekać.
class CheckWorktreeHealthJob < ApplicationJob
  queue_as :default
  # Dwa równoległe sprawdzenia tego samego review pisałyby po tych samych kolumnach.
  limits_concurrency key: ->(review, **) { review.id }

  def perform(review, health: WorktreeHealth)
    url = review.worktree_url
    # Selfreview w repo projektu albo projekt bez wzorca adresu — nie ma czego pukać.
    return if url.blank?

    review.record_worktree_health(health.check(url))
  end
end
