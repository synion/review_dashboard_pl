# Pyta tracker o bieżącą liczbę komentarzy w zadaniu. Zlecany z ReviewsController#show
# (raz na TASK_COMMENTS_CHECK_INTERVAL), bo opis zadania to zdjęcie z chwili jego
# generowania - ustalenia z nowych komentarzy review nie zna, a panel ma o tym mówić.
class CheckTaskCommentsJob < ApplicationJob
  queue_as :default

  def perform(review)
    count = review.task_comments_count_now
    attrs = { task_comments_checked_at: Time.current }
    attrs[:task_comments_latest] = count if count
    review.update!(attrs)
  end
end
