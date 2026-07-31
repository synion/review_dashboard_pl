class AddFollowupActions < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :second_reviewer_default, :string
    add_column :projects, :approve_label_default, :string

    add_column :reviews, :followup_reviewer_login, :string
    add_column :reviews, :followup_reviewer_status, :string
    add_column :reviews, :followup_label_name, :string
    add_column :reviews, :followup_label_status, :string
    add_column :reviews, :pr_reviewers, :text
    add_column :reviews, :pr_reviewers_checked_at, :datetime
  end
end
