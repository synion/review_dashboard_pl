# Pyta tracker o bieżącą liczbę komentarzy w zadaniu. Zlecany z ReviewsController#show
# (raz na TASK_COMMENTS_CHECK_INTERVAL), bo opis zadania to zdjęcie z chwili jego
# generowania - ustalenia z nowych komentarzy review nie zna, a panel ma o tym mówić.
class CheckTaskCommentsJob < ApplicationJob
  queue_as :default

  # Przy okazji odświeża tytuł zadania - to jedyne cykliczne pytanie do trackera.
  def perform(review)
    review.update!(review.tracker_task_attrs.merge(task_comments_checked_at: Time.current))
  end
end
