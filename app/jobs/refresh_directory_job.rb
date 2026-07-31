# Przeładowuje lokalny cache list do comboboxów (directory_entries). Odpalany
# przyciskiem „Odśwież" i leniwie przez endpoint directory, gdy cache się zestarzeje.
# Awaria klienta = zostaje ostatni znany stan — odświeżenie podpowiedzi nie może
# niczego wywalać.
class RefreshDirectoryJob < ApplicationJob
  queue_as :default

  def perform(project, github: GithubClient.new)
    refresh_github(project, github) if project.github_slug
  end

  private

  def refresh_github(project, github)
    collaborators = github.collaborators(repo: project.github_slug, repo_dir: project.repo_path)
                          .map { |c| { external_id: c["login"], name: c["login"] } }
    DirectoryEntry.replace!(project, "gh_collaborator", collaborators)

    labels = github.labels(repo_dir: project.repo_path).map { |l| { external_id: l["name"], name: l["name"] } }
    DirectoryEntry.replace!(project, "gh_label", labels)
  rescue GithubClient::Error => e
    Rails.logger.warn("RefreshDirectoryJob projekt #{project.id}: #{e.message}")
  end
end
