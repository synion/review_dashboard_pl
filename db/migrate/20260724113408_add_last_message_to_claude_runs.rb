class AddLastMessageToClaudeRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :claude_runs, :last_message, :text
  end
end
