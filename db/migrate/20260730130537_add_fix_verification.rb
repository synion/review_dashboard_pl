class AddFixVerification < ActiveRecord::Migration[8.1]
  def change
    # Punkt odniesienia weryfikacji: stan PR-a w chwili wysłania decyzji. Bez niego
    # nie da się powiedzieć, co autor zmienił PO review — `updatedAt` PR-a podnosi
    # też każdy komentarz, a `git log` nie wie, kiedy patrzyłem na kod.
    add_column :reviews, :decision_head_sha, :string
    add_column :reviews, :fixes_checked_at, :datetime
    add_column :findings, :fix_status, :string
    add_column :findings, :fix_note, :text
  end
end
