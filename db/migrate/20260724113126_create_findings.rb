class CreateFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :findings do |t|
      t.references :review, null: false, foreign_key: true
      t.string :priority
      t.string :title
      t.text :body
      t.string :file_location

      t.timestamps
    end
  end
end
