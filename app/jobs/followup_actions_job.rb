# Akcje po decyzji w tle — `gh pr edit` to ~2 s spawnu na akcję, a decyzja to
# najbardziej interaktywna akcja w apce; user nie czeka na dodatki. Wynik
# widać w panelu broadcastem po update! statusów.
class FollowupActionsJob < ApplicationJob
  queue_as :default

  def perform(review)
    FollowupActions.call(review)
  end
end
