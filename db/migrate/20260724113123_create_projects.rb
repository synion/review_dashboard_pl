class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name
      t.string :repo_path
      t.string :default_claude_config
      t.string :worktree_command
      t.text :review_prompt_extra

      t.timestamps
    end
  end
end
