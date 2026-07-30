class AddContextMetricsToClaudeRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :claude_runs, :context_tokens, :integer
    add_column :claude_runs, :context_window, :integer
    add_column :claude_runs, :cache_read_tokens, :integer
    add_column :claude_runs, :cache_creation_tokens, :integer
  end
end
