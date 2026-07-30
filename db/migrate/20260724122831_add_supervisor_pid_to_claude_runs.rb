class AddSupervisorPidToClaudeRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :claude_runs, :supervisor_pid, :integer
  end
end
