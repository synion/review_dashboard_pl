class AddFollowupFieldsToClaudeRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :claude_runs, :user_message, :text
    add_column :claude_runs, :resume_session_id, :string
  end
end
