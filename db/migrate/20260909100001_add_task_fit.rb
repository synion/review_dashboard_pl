class AddTaskFit < ActiveRecord::Migration[8.1]
  def change
    # Lista AC i pułapek z opisu zadania (id stabilne w obrębie jednego opisu).
    add_column :reviews, :task_criteria, :json
    # Wynik świeżej sesji task_fit plus werdykt policzony w importerze.
    add_column :reviews, :task_fit, :json
    add_column :reviews, :task_fit_status, :string, null: false, default: "skipped"
    add_column :reviews, :task_fit_checked_at, :datetime
    # Co człowiek odhaczył przy decyzji (checklista AC + override).
    add_column :reviews, :decision_checklist, :json
    # Kto i gdzie podważył decyzję (PR albo zadanie) - do banera i wiadomości followupu.
    add_column :reviews, :challenge, :json
    # Liczba komentarzy w zadaniu w chwili decyzji - wzrost = podważenie w trackerze.
    add_column :reviews, :decision_task_comments_count, :integer
    add_column :findings, :source, :string, null: false, default: "review"
  end
end
