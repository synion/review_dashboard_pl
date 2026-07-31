class AddFollowupActions < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :second_reviewer_default, :string
    add_column :projects, :approve_label_default, :string

    # Statusy wg konwencji TASK_COMMENT_STATUSES (queued/sent/failed), powód
    # porażki osobno — status ma zostać wartością z zamkniętej listy.
    add_column :reviews, :followup_reviewer_login, :string
    add_column :reviews, :followup_reviewer_status, :string
    add_column :reviews, :followup_reviewer_error, :string
    add_column :reviews, :followup_label_name, :string
    add_column :reviews, :followup_label_status, :string
    add_column :reviews, :followup_label_error, :string
    add_column :reviews, :pr_reviewers, :json
    add_column :reviews, :pr_reviewers_checked_at, :datetime
  end
end
