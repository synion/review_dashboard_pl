# Jednorazowe dociągnięcie tytułów zadań dla review sprzed kolumny task_title.
# Później tytuł odświeża się sam (opis zadania, okresowe sprawdzenie komentarzy).
namespace :reviews do
  desc "Pobiera z trackera tytuły zadań dla review bez task_title"
  task backfill_task_titles: :environment do
    scope = Review.where(task_title: nil).where.not(task_url: [ nil, "" ]).includes(:project)
    done = scope.count { |review| (attrs = review.tracker_task_attrs).any? && review.update_columns(attrs) }
    puts "uzupełniono #{done} z #{scope.size}"
  end
end
