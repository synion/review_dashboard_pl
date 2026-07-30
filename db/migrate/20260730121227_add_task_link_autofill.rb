class AddTaskLinkAutofill < ActiveRecord::Migration[8.1]
  def change
    # Prefiks adresu zadania w trackerze projektu. Dashboard jest neutralny wobec
    # trackera, więc wzorca nie da się zahardkodować — bez tego pola autouzupełnianie
    # linku z opisu PR-a jest wyłączone.
    add_column :projects, :task_url_prefix, :string
    add_column :inbox_items, :task_url, :string
  end
end
