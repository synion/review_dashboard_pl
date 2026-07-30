class AddModelAndEffortToReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :reviews, :model, :string
    add_column :reviews, :effort, :string
  end
end
