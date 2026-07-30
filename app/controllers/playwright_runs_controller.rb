class PlaywrightRunsController < ApplicationController
  def create
    review = Review.find(params[:review_id])
    mode = PlaywrightRun::MODES.include?(params[:mode]) ? params[:mode] : "headless"
    run = review.playwright_runs.create!(mode: mode, status: "running")
    PlaywrightRunJob.perform_later(run)
    redirect_to review_path(review), notice: mode == "headed" ? "Przeglądarka zaraz się otworzy — patrz na ekran" : "Odpalam szybką weryfikację"
  end
end
