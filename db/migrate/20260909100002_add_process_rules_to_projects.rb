class AddProcessRulesToProjects < ActiveRecord::Migration[8.1]
  def change
    # Wymogi procesu zespołu (np. „nowy feature: link do Figmy, analiza przed
    # implementacją”) - describe_task sprawdza je na zadaniu, brak = czerwone.
    add_column :projects, :process_rules, :text
  end
end
