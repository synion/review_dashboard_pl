# Lokalny cache list do comboboxów (collaboratorzy i labelki z GH, osoby z trackera).
# Selecty filtrują po tej tabeli zamiast pytać zewnętrzne API przy każdym wpisanym znaku.
class DirectoryEntry < ApplicationRecord
  KINDS = %w[gh_collaborator gh_label tracker_user].freeze
  STALE_AFTER = 12.hours

  belongs_to :project

  validates :kind, inclusion: { in: KINDS }

  # Jedno źródło walidacji kindu z requestu (wzorzec Review.claude_config?).
  def self.kind?(kind)
    KINDS.include?(kind)
  end

  # Podpowiedzi dla comboboxa: fragment nazwy, po nazwie. LIKE w SQLite nie
  # rozróżnia wielkości liter (ASCII), więc bez LOWER — nie unieważnia indeksu.
  # Limit trzyma odpowiedź małą — user i tak doprecyzuje wpisując dalej.
  def self.search(project, kind, query, limit: 20)
    scope = project.directory_entries.where(kind: kind).order(:name).limit(limit)
    return scope if query.blank?

    scope.where("name LIKE ?", "%#{sanitize_sql_like(query)}%")
  end

  # Transakcyjna podmiana całej listy danego kind: jeden upsert po istniejącym
  # unikalnym indeksie zamiast pary zapytań na wpis; wpisy nieobecne w nowej
  # liście znikają.
  def self.replace!(project, kind, entries)
    now = Time.current
    rows = entries.map do |entry|
      { project_id: project.id, kind: kind, external_id: entry[:external_id],
        name: entry[:name], refreshed_at: now, created_at: now, updated_at: now }
    end
    transaction do
      project.directory_entries.where(kind: kind)
             .where.not(external_id: rows.map { |r| r[:external_id] }).delete_all
      upsert_all(rows, unique_by: %i[project_id kind external_id]) if rows.any?
    end
  end

  # Cache danego kind uznajemy za stęchły, gdy pusty albo nieodświeżany pół dnia —
  # wtedy endpoint directory zleca RefreshDirectoryJob w tle.
  def self.stale?(project, kind)
    last = project.directory_entries.where(kind: kind).maximum(:refreshed_at)
    last.nil? || last < STALE_AFTER.ago
  end
end
