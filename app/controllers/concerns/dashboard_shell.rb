# Dane strony wejściowej dla jej partiali (_dashboard, _grid, _summary, _queues).
#
# Strona wejściowa w układzie dwukolumnowym jest też obudową prawego panelu: lista
# review, review i formularz nowego review wejściem adresem (F5, „wstecz", link
# z czatu) renderują się w niej, zamiast wypadać na gołą podstronę — patrz
# ViewModeHelper#detail_page. Leniwie, przez helper_method: partiale same proszą
# o to, czego potrzebują, więc żaden render (także błędu 422 z innego kontrolera)
# nie może zapomnieć czegoś załadować, a zapytanie z ramki nie płaci za dashboard.
module DashboardShell
  extend ActiveSupport::Concern

  included do
    helper_method :current_dashboard, :archived_projects, :review_counts
  end

  private

  # Same liczby siedzą w Dashboard, bo z tego samego stanu renderuje kolejki
  # BroadcastDashboardJob.
  def current_dashboard = @current_dashboard ||= Dashboard.new

  # to_a: partial pyta o any?, size i each — na relacji to byłyby trzy zapytania.
  def archived_projects = @archived_projects ||= Project.archived.by_name.to_a

  # Dwa zapytania GROUP BY na całą listę zamiast trzech na projekt. „czeka"
  # i „w toku" liczą tylko outward (selfreview nie woła o uwagę — patrz
  # Review.outward); „łącznie" liczy wszystko, bo tyle naprawdę jest w projekcie.
  def review_counts
    @review_counts ||= begin
      counts = Hash.new { |hash, key| hash[key] = { attention: 0, in_progress: 0, total: 0 } }
      Review.group(:project_id).count.each { |project_id, number| counts[project_id][:total] = number }
      Review.outward.group(:project_id, :status).count.each do |(project_id, status), number|
        bucket = counts[project_id]
        bucket[:attention] += number if Review::ATTENTION_STATUSES.include?(status)
        bucket[:in_progress] += number if Review::IN_PROGRESS_STATUSES.include?(status)
      end
      counts
    end
  end
end
