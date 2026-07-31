class AddFindingVerdicts < ActiveRecord::Migration[8.1]
  def change
    # Werdykt świeżej sesji weryfikującej zasadność znaleziska — osobno od
    # fix_status, który mówi o losie poprawki autora, nie o słuszności uwagi.
    add_column :findings, :verdict, :string
    add_column :findings, :verdict_note, :text
    add_column :reviews, :findings_verified_at, :datetime
  end
end
