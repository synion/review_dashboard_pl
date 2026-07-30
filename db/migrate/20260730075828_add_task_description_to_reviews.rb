class AddTaskDescriptionToReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :reviews, :task_description, :text
    # Default "skipped": istniejące review nie mają opisu zadania i panel ma
    # dla nich pokazać przycisk „Generuj", nie wieczny spinner.
    add_column :reviews, :task_description_status, :string, null: false, default: "skipped"
  end
end
