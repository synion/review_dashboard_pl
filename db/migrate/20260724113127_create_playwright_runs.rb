class CreatePlaywrightRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :playwright_runs do |t|
      t.references :review, null: false, foreign_key: true
      t.string :mode
      t.string :status
      t.integer :exit_code
      t.string :output_path

      t.timestamps
    end
  end
end
