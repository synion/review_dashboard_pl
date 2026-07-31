class CreateDirectoryEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :directory_entries do |t|
      t.references :project, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :external_id, null: false
      t.string :name, null: false
      t.datetime :refreshed_at
      t.timestamps
    end
    add_index :directory_entries, %i[project_id kind external_id], unique: true
    add_index :directory_entries, %i[project_id kind name]
  end
end
