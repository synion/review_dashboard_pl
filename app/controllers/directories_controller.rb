# Podpowiedzi do comboboxów: filtruje lokalny cache (directory_entries), więc
# odpowiada natychmiast; przy okazji zleca odświeżenie w tle, gdy cache się
# zestarzeje — user dostaje ostatni znany stan zamiast czekać na GH/tracker.
class DirectoriesController < ApplicationController
  def show
    project = Project.find(params[:id])
    kind = params[:kind].to_s
    return head :unprocessable_entity unless DirectoryEntry::KINDS.include?(kind)

    RefreshDirectoryJob.perform_later(project) if DirectoryEntry.stale?(project, kind)
    entries = DirectoryEntry.search(project, kind, params[:q].to_s)
    render json: entries.map { |e| { id: e.external_id, name: e.name } }
  end

  def refresh
    project = Project.find(params[:id])
    RefreshDirectoryJob.perform_later(project)
    redirect_to edit_project_path(project), notice: "Odświeżanie list podpowiedzi w tle"
  end
end
