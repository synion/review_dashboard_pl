# Przeładowuje lokalny cache list do comboboxów (directory_entries). Odpalany
# przyciskiem „Odśwież" i leniwie przez endpoint directory, gdy cache się
# zestarzeje. Awaria klienta = zostaje ostatni znany stan — odświeżenie
# podpowiedzi nie może niczego wywalać.
class RefreshDirectoryJob < ApplicationJob
  queue_as :default
  # Dwa joby tego samego projektu i kindu ścigałyby się na delete_all + upsert
  # po tym samym unikalnym indeksie (wzorzec z RefreshInboxJob). Klucz z kindem:
  # refresh GH i refresh trackera dotykają rozłącznych wierszy, więc mogą iść
  # równolegle; `kind: nil` (przycisk „Odśwież") serializuje się sam ze sobą.
  limits_concurrency key: ->(project, kind: nil, **) { [ project.id, kind ] }

  # Endpoint directory kolejkuje odświeżenie tylko dla kindów, które ten job
  # umie wypełnić — inaczej kind bez producenta kolejkowałby joby bez końca,
  # bo jego cache nigdy nie przestanie być stęchły.
  def self.refreshable?(project, kind)
    case kind
    when "gh_collaborator", "gh_label" then project.github_slug.present?
    when "intum_user" then project.intum_enabled?
    else false
    end
  end

  # `kind` z leniwego odświeżenia endpointu directory zawęża pracę do providera,
  # którego cache faktycznie zwietrzał — stęchłe labelki nie odpalają pełnej
  # paginacji userów trackera. Przycisk „Odśwież" woła bez kind = wszystko.
  def perform(project, kind: nil, github: GithubClient.new, intum: nil)
    refresh_github(project, github) if kind.nil? || kind.start_with?("gh_")
    refresh_intum(project, intum) if kind.nil? || kind == "intum_user"
  end

  private

  def refresh_github(project, github)
    return if project.github_slug.blank?

    DirectoryEntry.replace!(project, "gh_collaborator",
                            as_entries(github.collaborators(repo: project.github_slug, repo_dir: project.repo_path)))
    DirectoryEntry.replace!(project, "gh_label", as_entries(github.labels(repo_dir: project.repo_path)))
  rescue GithubClient::Error => e
    Rails.logger.warn("RefreshDirectoryJob projekt #{project.id}: #{e.message}")
  end

  def refresh_intum(project, intum)
    return unless project.intum_enabled?

    intum ||= project.intum_client
    DirectoryEntry.replace!(project, "intum_user",
                            intum.users.map { |u| { external_id: u["id"], name: u["name"] } })
  rescue IntumClient::Error => e
    Rails.logger.warn("RefreshDirectoryJob projekt #{project.id} (intum): #{e.message}")
  end

  # Loginy i nazwy labelek identyfikują się same — id i nazwa to to samo.
  def as_entries(names)
    names.map { |name| { external_id: name, name: name } }
  end
end
