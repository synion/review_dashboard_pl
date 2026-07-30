class AddInboxCheckedAtToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :inbox_checked_at, :datetime
  end
end
