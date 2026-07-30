class AddDecisionBodyToReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :reviews, :decision_body, :text
  end
end
