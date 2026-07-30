class AddRawResultToReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :reviews, :raw_result, :text
  end
end
