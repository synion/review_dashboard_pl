class AddMultiProjectColumnsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :repo_url, :string
    add_column :projects, :default_model, :string
    add_column :projects, :default_effort, :string
    add_column :projects, :archived_at, :datetime
  end
end
