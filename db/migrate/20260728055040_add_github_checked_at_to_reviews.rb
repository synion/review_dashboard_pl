class AddGithubCheckedAtToReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :reviews, :github_checked_at, :datetime
  end
end
