class AddDocsPathToProjects < ActiveRecord::Migration[8.1]
  # Default zamiast NULL: każde repo, które trzymamy w dashboardzie, ma dokumentację
  # dla modeli w doc/llm. Projekt, który jej nie ma, i tak nie dostanie sekcji promptu —
  # Review#available_docs_path sprawdza, czy katalog realnie istnieje na dysku.
  def change
    add_column :projects, :docs_path, :string, default: "doc/llm"
  end
end
