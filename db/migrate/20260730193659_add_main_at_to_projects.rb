class AddMainAtToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :main_at, :datetime
  end
end
