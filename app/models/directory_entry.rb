# Lokalny cache list do comboboxów (collaboratorzy i labelki z GH, osoby z trackera).
# Selecty filtrują po tej tabeli zamiast pytać zewnętrzne API przy każdym wpisanym znaku.
class DirectoryEntry < ApplicationRecord
  KINDS = %w[gh_collaborator gh_label intum_user].freeze

  belongs_to :project

  validates :kind, inclusion: { in: KINDS }

  # Podpowiedzi dla comboboxa: fragment nazwy, bez wielkości liter, po nazwie.
  # Limit trzyma odpowiedź małą — user i tak doprecyzuje wpisując dalej.
  def self.search(project, kind, query, limit: 20)
    raise ArgumentError, "nieznany kind: #{kind}" unless KINDS.include?(kind)

    scope = project.directory_entries.where(kind: kind).order(:name).limit(limit)
    return scope if query.blank?

    scope.where("LOWER(name) LIKE ?", "%#{sanitize_sql_like(query.downcase)}%")
  end

  # Transakcyjna podmiana całej listy danego kind: upsert po external_id
  # (nazwa może się zmienić), wpisy nieobecne w nowej liście znikają.
  def self.replace!(project, kind, entries)
    raise ArgumentError, "nieznany kind: #{kind}" unless KINDS.include?(kind)

    now = Time.current
    transaction do
      project.directory_entries.where(kind: kind)
             .where.not(external_id: entries.map { |e| e[:external_id] }).delete_all
      entries.each do |entry|
        project.directory_entries.find_or_initialize_by(kind: kind, external_id: entry[:external_id])
               .update!(name: entry[:name], refreshed_at: now)
      end
    end
  end

  # Cache danego kind uznajemy za stęchły, gdy pusty albo nieodświeżany pół dnia —
  # wtedy endpoint directory zleca RefreshDirectoryJob w tle.
  def self.stale?(project, kind)
    last = project.directory_entries.where(kind: kind).maximum(:refreshed_at)
    last.nil? || last < 12.hours.ago
  end
end
