# Podpowiedzi do comboboxów: filtruje lokalny cache (directory_entries), więc
# odpowiada natychmiast; przy okazji zleca odświeżenie w tle, gdy cache się
# zestarzeje — user dostaje ostatni znany stan zamiast czekać na GH/tracker.
class DirectoriesController < ApplicationController
  before_action :set_project

  def show
    kind = params[:kind].to_s
    return head :unprocessable_entity unless DirectoryEntry.kind?(kind)

    refresh_stale(kind)
    entries = DirectoryEntry.search(@project, kind, params[:q].to_s)
    render json: entries.map { |e| { id: e.external_id, name: e.name } }
  end

  def refresh
    RefreshDirectoryJob.perform_later(@project)
    redirect_to edit_project_path(@project), notice: "Odświeżanie list podpowiedzi w tle"
  end

  private

  def set_project
    @project = Project.find(params[:id])
  end

  # Combobox strzela co znak — marker w cache trzyma jeden job w locie zamiast
  # sztormu identycznych; tylko dla kindów, które job umie wypełnić.
  def refresh_stale(kind)
    return unless RefreshDirectoryJob.refreshable?(@project, kind) && DirectoryEntry.stale?(@project, kind)

    Rails.cache.fetch("directory_refresh_#{@project.id}_#{kind}", expires_in: 5.minutes) do
      RefreshDirectoryJob.perform_later(@project, kind: kind)
      true
    end
  end
end
