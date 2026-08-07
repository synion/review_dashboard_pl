# Stan strony wejściowej policzony w jednym miejscu. Kontroler renderuje z niego
# pierwsze wejście, BroadcastDashboardJob — każde kolejne odświeżenie kolejek
# z tła. Dopóki partiale czytały ivary kontrolera, broadcast renderował je
# z samymi nilami, więc kolejki mogły się aktualizować tylko przez F5.
#
# Klasa jest czytelnikiem: NIC nie zleca i nic nie zapisuje. Efekty uboczne
# strony wejściowej (odświeżenie kolejki z GitHuba, sprawdzenie statusu PR-ów)
# zostają w kontrolerze — job broadcastu nie może ich odpalać w kółko.
class Dashboard
  attr_reader :main_project

  def initialize(main_project: Project.main)
    @main_project = main_project
  end

  def projects = @projects ||= Project.active.by_name

  # „Czeka na Twoje review" znaczy „kliknij", więc PR z pracującą (albo zakolejkowaną)
  # sesją z niej wypada — jego miejsce jest w „W toku", gdzie nic się nie klika.
  # Bez tego ten sam PR stał w dwóch sekcjach naraz i pierwsza kłamała, że czeka
  # na decyzję człowieka.
  def inbox_items
    @inbox_items ||= all_inbox_items.reject do |item|
      review = inbox_reviews[[ item.project_id, item.pr_number ]]
      review && Review::IN_PROGRESS_STATUSES.include?(review.status)
    end
  end

  # Review dla tych PR-ów, żeby kafel wiedział, czy prowadzi do istniejącego review,
  # czy proponuje założenie nowego. Jedno zapytanie, nie jedno na kafel. Liczone
  # z PEŁNEJ kolejki, bo to na jego podstawie inbox_items odsiewa pracujące.
  def inbox_reviews
    @inbox_reviews ||= Review.where(project: main_project, pr_number: all_inbox_items.map(&:pr_number))
                             .index_by { |review| [ review.project_id, review.pr_number ] }
  end

  def inbox_checked_at = main_project&.inbox_checked_at

  # Jeden PR = jedna karta. Review, którego PR wisi już w kolejce z GitHuba, nie wraca
  # niżej w drugiej sekcji: to ta sama robota opisana dwa razy, tylko innym zegarem
  # (sygnał z GitHuba vs ostatni ruch w dashboardzie). Kafel kolejki dowozi za to stan
  # review i następny krok — patrz projects/_inbox_item.
  def attention_reviews
    @attention_reviews ||= begin
      in_inbox = inbox_items.map(&:pr_number).compact
      waiting.select { |r| r.status.in?(Review::ATTENTION_STATUSES) }
             .reject { |r| r.pr_number.present? && in_inbox.include?(r.pr_number) }
             .sort_by { |r| [ Review::ATTENTION_ORDER.index(r.status), r.updated_at ] }
    end
  end

  def in_progress_reviews
    @in_progress_reviews ||= waiting.select { |r| r.status.in?(Review::IN_PROGRESS_STATUSES) }
                                    .sort_by(&:updated_at).reverse
  end

  # Te same sygnały co na liście review, jednym zapytaniem: „reviewing" bez
  # pracującej sesji znaczy, że job stoi w kolejce workera, a weryfikacja uwag
  # (pending też) nie zmienia statusu review, więc kafel musi o niej wiedzieć sam.
  def running_review_ids
    @running_review_ids ||= active_runs.filter_map { |review_id, _kind, status| review_id if status == "running" }.uniq
  end

  def verifying_review_ids
    @verifying_review_ids ||= active_runs.filter_map { |review_id, kind, _status| review_id if kind == "verify_findings" }.uniq
  end

  # Review z projektu głównego, których dotyczy którakolwiek kolejka — jednym
  # zapytaniem, bo kolejność „Czeka na Ciebie" i tak sortuje się w Ruby (po
  # ATTENTION_ORDER, czego SQLite nie wyrazi bez CASE dłuższego niż ta klasa).
  # outward: selfreview to prywatna runda przed PR-em — jego wynik czeka na liście
  # projektu, a nie w kolejkach „co teraz kliknąć" na stronie wejściowej.
  def waiting
    @waiting ||= Review.outward
                       .where(project: main_project,
                              status: Review::ATTENTION_STATUSES + Review::IN_PROGRESS_STATUSES)
                       .includes(:project, :findings).to_a
  end

  private

  # Widok pokazuje wyłącznie projekt główny — kolejki różnych projektów mieszały
  # się nie do odróżnienia.
  def all_inbox_items
    @all_inbox_items ||= InboxItem.where(project: main_project).includes(:project).by_urgency.to_a
  end

  def active_runs
    @active_runs ||= ClaudeRun.where(status: "running")
                              .or(ClaudeRun.where(kind: "verify_findings", status: "pending"))
                              .pluck(:review_id, :kind, :status)
  end
end
