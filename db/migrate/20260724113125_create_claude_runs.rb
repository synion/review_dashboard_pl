class CreateClaudeRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :claude_runs do |t|
      t.references :review, null: false, foreign_key: true
      t.string :kind
      t.string :status
      t.string :session_id
      t.string :claude_config
      t.integer :pid
      t.decimal :cost_usd, precision: 10, scale: 4
      t.integer :duration_ms
      t.text :error_message
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end
  end
end
