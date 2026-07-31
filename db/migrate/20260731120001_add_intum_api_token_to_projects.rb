class AddIntumApiTokenToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :intum_api_token, :string
    # Skierowanie komentarza po review do osoby (drugie sprawdzenie) — id + nazwa
    # z comboboxa, zamrożone na review razem z decyzją.
    add_column :reviews, :task_comment_responsible_id, :string
    add_column :reviews, :task_comment_responsible_name, :string
  end
end
