# Uzgodnienie wyniku review: los znaleziska po uzgodnieniu, werdykt zgodności z zadaniem
# i status runa sprzed uzgodnienia (do przywrócenia po jego zakończeniu).
class AddReconcileFields < ActiveRecord::Migration[8.1]
  def change
    add_column :findings, :resolution, :string
    add_column :findings, :resolution_note, :text
    add_column :reviews, :task_fit_reconciliation, :json
    add_column :claude_runs, :previous_status, :string
  end
end
