class CreateInboxItems < ActiveRecord::Migration[8.1]
  def change
    create_table :inbox_items do |t|
      t.references :project, null: false, foreign_key: true
      t.integer :pr_number
      t.string :title
      t.string :url
      t.string :author
      t.string :reason
      t.datetime :signal_at
      t.string :actor

      t.timestamps
    end
    # Kolejka jest przepisywana w całości przy każdym odświeżeniu z GitHuba, więc
    # jeden PR może w niej wystąpić tylko raz — indeks pilnuje tego przy insert_all,
    # które nie przechodzi przez walidacje modelu.
    add_index :inbox_items, %i[project_id pr_number], unique: true
  end
end
