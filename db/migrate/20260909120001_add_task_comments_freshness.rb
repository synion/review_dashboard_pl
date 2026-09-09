class AddTaskCommentsFreshness < ActiveRecord::Migration[8.1]
  def change
    # Liczba komentarzy w zadaniu, którą widział ostatni opis zadania, oraz ostatnio
    # sprawdzona bieżąca liczba - różnica = „opis nieaktualny, odśwież”.
    add_column :reviews, :task_comments_seen, :integer
    add_column :reviews, :task_comments_latest, :integer
    add_column :reviews, :task_comments_checked_at, :datetime
  end
end
