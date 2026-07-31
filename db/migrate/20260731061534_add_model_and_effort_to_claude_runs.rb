class AddModelAndEffortToClaudeRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :claude_runs, :model, :string
    add_column :claude_runs, :effort, :string
  end
end
