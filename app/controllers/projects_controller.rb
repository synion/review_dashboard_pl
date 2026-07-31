class ProjectsController < ApplicationController
  before_action :set_project, only: %i[edit update archive unarchive]

  def index
    @archived_projects = Project.archived.by_name
    @counts = review_counts
    load_dashboard
  end

  # Przełącznik projektu głównego — switcher u góry strony i radio „główny" na
  # karcie POST-ują tu to samo. Odpowiedź turbo_stream podmienia piguły, kolejki
  # i grid (żeby oba uchwyty pokazywały ten sam wybór) bez przeładowania strony.
  def select
    Project.active.find(params[:project_id]).make_main!
    respond_to do |format|
      format.turbo_stream do
        load_dashboard
        @counts = review_counts
      end
      # Fallback bez JS — pełny redirect i index policzy wszystko sam.
      format.html { redirect_to projects_path }
    end
  end

  # Kolejka odświeża się sama co GithubInbox::STALE_AFTER; ten przycisk pomija okno,
  # gdy wiem, że ktoś właśnie poprosił mnie o review i nie chcę czekać.
  def refresh_inbox
    Project.active.with_repo.each { |project| RefreshInboxJob.perform_later(project) }
    redirect_to projects_path, notice: "Pytam GitHuba o PR-y czekające na Twoje review…"
  end

  # docs_path ma "doc/llm" jako default w schemacie — jawne podanie tu byłoby
  # zdublowaniem tej samej wartości w dwóch miejscach.
  def new
    @project = Project.new
  end

  def create
    @project = Project.new(project_params)
    if @project.save
      redirect_to project_reviews_path(@project), notice: "Projekt dodany"
    else
      flash.now[:error] = @project.errors.full_messages.to_sentence
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @project.update(project_params)
      redirect_to project_reviews_path(@project), notice: "Ustawienia projektu zapisane"
    else
      flash.now[:error] = @project.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  # Projektów nie usuwamy: has_many :reviews, dependent: :destroy skasowałby całą
  # historię review razem z artefaktami i worktree. Archiwum zdejmuje projekt z oczu,
  # zostawiając wszystko, co już zrobił.
  def archive
    @project.update!(archived_at: Time.current)
    redirect_to projects_path, notice: "Projekt #{@project.name} zarchiwizowany"
  end

  def unarchive
    @project.update!(archived_at: nil)
    redirect_to projects_path, notice: "Projekt #{@project.name} przywrócony"
  end

  private

  def set_project
    @project = Project.find(params[:id])
  end

  # Wszystko, czego potrzebują partiale strony wejściowej (_summary, _queues, _grid)
  # — jedno miejsce dla index i select, żeby odpowiedź turbo_stream nie mogła się
  # rozjechać z pełnym renderem o brakujący ivar.
  def load_dashboard
    @projects = Project.active.by_name
    @main_project = Project.main
    load_inbox
    load_queues
  end

  def project_params
    params.require(:project).permit(:name, :repo_path, :repo_url, :default_claude_config, :default_model,
                                    :default_effort, :docs_path, :review_prompt_extra, :task_comment_instructions,
                                    :worktree_command, :worktree_delete_command, :task_url_prefix)
  end

  # Kolejka „czeka na Ciebie" to PR-y CZYJEGOŚ autorstwa, na których wisi moje review.
  # Renderujemy ostatni znany stan i dopiero zlecamy odświeżenie — inaczej pierwsze
  # wejście na stronę czekałoby kilka sekund na `gh`.
  def load_inbox
    # Widok pokazuje wyłącznie projekt główny — kolejki różnych projektów mieszały
    # się nie do odróżnienia. Odświeżanie w tle zostaje jednak dla WSZYSTKICH
    # aktywnych projektów, żeby przełączenie radia pokazywało świeży stan od razu.
    @inbox_items = InboxItem.where(project: @main_project).includes(:project).by_urgency.to_a
    # Review dla tych PR-ów, żeby kafel wiedział, czy prowadzi do istniejącego review,
    # czy proponuje założenie nowego. Jedno zapytanie, nie jedno na kafel.
    @inbox_reviews = Review.where(project: @main_project, pr_number: @inbox_items.map(&:pr_number))
                          .index_by { |review| [ review.project_id, review.pr_number ] }
    @inbox_checked_at = @main_project&.inbox_checked_at
    @projects.select { |project| project.repo_url.present? && project.inbox_stale? }
             .each { |project| RefreshInboxJob.perform_later(project) }
  end

  # Dwie kolejki jednym zapytaniem: sama liczba w kubełku nie mówi, CO zrobić, a to
  # jedyne pytanie, na które ta strona ma odpowiadać przy wejściu. Sortowanie w Ruby,
  # bo kolejność „Czeka na Ciebie" jest po statusie wg ATTENTION_ORDER, czego SQLite
  # nie wyrazi bez CASE dłuższego niż cała ta metoda.
  def load_queues
    # Scope na projekt główny (load_inbox wyżej filtruje tak samo) — archiwum
    # i tak odpada, bo Project.main widzi tylko aktywne.
    waiting = Review.where(project: @main_project,
                           status: Review::ATTENTION_STATUSES + Review::IN_PROGRESS_STATUSES)
                    .includes(:project, :findings).to_a
    # Jeden PR = jedna karta. Review, którego PR wisi już w kolejce z GitHuba, nie wraca
    # niżej w drugiej sekcji: to ta sama robota opisana dwa razy, tylko innym zegarem
    # (sygnał z GitHuba vs ostatni ruch w dashboardzie). Kafel kolejki dowozi za to stan
    # review i następny krok — patrz projects/_inbox_item.
    in_inbox = @inbox_items.map(&:pr_number).compact
    @attention_reviews = waiting.select { |r| r.status.in?(Review::ATTENTION_STATUSES) }
                                .reject { |r| r.pr_number.present? && in_inbox.include?(r.pr_number) }
                                .sort_by { |r| [ Review::ATTENTION_ORDER.index(r.status), r.updated_at ] }
    @in_progress_reviews = waiting.select { |r| r.status.in?(Review::IN_PROGRESS_STATUSES) }
                                  .sort_by(&:updated_at).reverse
    # Ten sam sygnał co na liście review: „reviewing" bez pracującej sesji znaczy,
    # że job stoi w kolejce workera. Pytamy tylko, gdy jest o co pytać.
    @running_review_ids = @in_progress_reviews.any? ? ClaudeRun.where(status: "running").distinct.pluck(:review_id) : []
  end

  # Jedno zapytanie na całą listę zamiast trzech na projekt. GROUP BY oddaje
  # pary [project_id, status], kubełki składamy w Ruby.
  def review_counts
    counts = Hash.new { |hash, key| hash[key] = { attention: 0, in_progress: 0, total: 0 } }
    Review.group(:project_id, :status).count.each do |(project_id, status), number|
      bucket = counts[project_id]
      bucket[:total] += number
      bucket[:attention] += number if Review::ATTENTION_STATUSES.include?(status)
      bucket[:in_progress] += number if Review::IN_PROGRESS_STATUSES.include?(status)
    end
    counts
  end
end
