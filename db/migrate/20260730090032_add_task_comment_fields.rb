class AddTaskCommentFields < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :task_comment_instructions, :text

    add_column :reviews, :task_comment_status, :string, default: "skipped", null: false
    add_column :reviews, :task_comment, :text
    add_column :reviews, :task_comment_instructions, :text
  end
end
