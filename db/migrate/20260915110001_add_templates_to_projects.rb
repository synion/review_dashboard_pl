class AddTemplatesToProjects < ActiveRecord::Migration[8.1]
  def change
    # Własne szablony wypowiedzi projektu: { rodzina => { werdykt => szablon Mustache } },
    # rodziny wg MessageTemplate.families (treść decyzji, komentarz przy linii,
    # ponowne sprawdzenie, podważenie). Brak wpisu = domyślny szablon rodziny.
    add_column :projects, :templates, :json
  end
end
