class AddPrActivityAtToReviews < ActiveRecord::Migration[8.1]
  def change
    # `updatedAt` PR-a z GitHuba — odświeżane przy okazji CheckReviewRequestJob.
    # Nil = jeszcze nigdy nie sprawdzono (stare review, brak PR-a).
    add_column :reviews, :pr_activity_at, :datetime
  end
end
