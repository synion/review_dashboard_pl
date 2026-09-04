class AddWorktreeUrlTemplateToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :worktree_url_template, :string
  end
end
