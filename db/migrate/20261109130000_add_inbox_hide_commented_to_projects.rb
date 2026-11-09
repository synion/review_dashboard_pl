class AddInboxHideCommentedToProjects < ActiveRecord::Migration[8.1]
  def change
    # Filtr kolejki: chowa „Odezwał się po Twoim review", zostawia same prośby o review.
    add_column :projects, :inbox_hide_commented, :boolean, default: false, null: false
  end
end
