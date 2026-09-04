class AddWorktreeHealthToReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :reviews, :worktree_health_status, :string
    add_column :reviews, :worktree_health_error, :string
    add_column :reviews, :worktree_health_checked_at, :datetime
  end
end
