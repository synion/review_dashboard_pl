# Podgląd zmian w PR-ze: diff z komentarzami ludzi i pinezkami znalezisk.
# Dane pochodzą z artefaktu (PrSnapshot); pobranie z GitHuba idzie w tle, bo to
# trzy spawny `gh` i request nie ma na nie czekać.
class PrDiffsController < ApplicationController
  before_action :set_review

  def show
    return redirect_to(review_path(@review), alert: "To review nie ma PR-a — nie ma czego pokazać") if @review.pr_url.blank?

    remember_view_mode
    @snapshot = PrSnapshot.load(@review)
    # Stęchły artefakt też renderujemy: lepiej wczorajszy diff z adnotacją „stan na"
    # niż pusty ekran na czas pobierania. Broadcast joba przeładuje stronę, gdy dojdą
    # świeże dane.
    FetchPrSnapshotJob.enqueue(@review) if @snapshot.nil? || @snapshot.stale?(@review)
    @error = Rails.cache.read(FetchPrSnapshotJob.error_key(@review))
    @presenter = build_presenter
  end

  def refresh
    FetchPrSnapshotJob.enqueue(@review, force: true)
    redirect_to diff_review_path(@review)
  end

  private

  def set_review
    @review = Review.find(params[:id])
  end

  def build_presenter
    return nil if @snapshot.nil?

    DiffPresenter.new(@snapshot, findings: @review.findings.order(:priority),
                      mode: helpers.diff_view, expanded: Array(params[:expand]))
  end

  # Wybór trybu przyjeżdża w linku, a zostaje w ciasteczku — jak przełącznik układu
  # strony wejściowej. Bez zapamiętania trzeba by go klikać po każdym wejściu.
  def remember_view_mode
    mode = params[:view].to_s
    cookies.permanent[DiffViewHelper::COOKIE] = mode if DiffPresenter::MODES.include?(mode)
  end
end
