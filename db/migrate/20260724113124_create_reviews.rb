class CreateReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :reviews do |t|
      t.references :project, null: false, foreign_key: true
      t.string :pr_url
      t.string :task_url
      t.string :branch
      t.string :worktree_path
      t.string :status, default: "created", null: false
      t.string :decision
      t.json :scope
      t.text :description
      t.text :summary
      t.integer :pr_number
      t.string :pr_title
      t.string :playwright_test_path
      t.string :playwright_command
      t.text :error_message
      t.datetime :decided_at

      t.timestamps
    end
  end
end
