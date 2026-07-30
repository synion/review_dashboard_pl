class AddWorktreeDeleteCommandToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :worktree_delete_command, :string
  end
end
