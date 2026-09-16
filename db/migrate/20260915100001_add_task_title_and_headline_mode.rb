class AddTaskTitleAndHeadlineMode < ActiveRecord::Migration[8.1]
  def change
    # Tytuł zadania z trackera - do nagłówków listy i strony review, obok tytułu PR-a.
    add_column :reviews, :task_title, :string
    # Który tytuł jest nagłówkiem review w projekcie: pr / task / both.
    add_column :projects, :headline_mode, :string, default: "pr", null: false
  end
end
