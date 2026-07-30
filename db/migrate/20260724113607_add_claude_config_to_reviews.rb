class AddClaudeConfigToReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :reviews, :claude_config, :string
  end
end
