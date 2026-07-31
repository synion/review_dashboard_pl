# Przeładowuje lokalny cache list do comboboxów (directory_entries). Odpalany
# przyciskiem „Odśwież" i leniwie przez endpoint directory, gdy cache się
# zestarzeje. Awaria klienta = zostaje ostatni znany stan — odświeżenie
# podpowiedzi nie może niczego wywalać.
class RefreshDirectoryJob < ApplicationJob
  queue_as :default
  # Dwa joby tego samego projektu ścigałyby się na delete_all + upsert
  # po tym samym unikalnym indeksie (wzorzec z RefreshInboxJob).
  limits_concurrency key: ->(project, **) { project.id }

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

  def perform(project, github: GithubClient.new, intum: nil)
    refresh_github(project, github)
    refresh_intum(project, intum)
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

    intum ||= IntumClient.new(base_url: project.intum_base_url, token: project.intum_api_token)
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
