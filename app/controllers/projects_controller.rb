class ProjectsController < ApplicationController
  before_action :set_project, only: %i[edit update archive unarchive test_intum]

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

  # Szybka odpowiedź „czy token działa": jedna strona listy osób (nie cała
  # paginacja — to potrafi być kilkanaście requestów, a wynik i tak tylko
  # potwierdza uprawnienia). Liczba osób zamiast gołego OK — od razu widać,
  # czy uprawnienia obejmują listę userów.
  def test_intum
    return redirect_to(edit_project_path(@project), alert: "Najpierw zapisz prefiks zadań i token") unless @project.intum_enabled?

    people = @project.intum_client.users(limit_pages: 1)
    redirect_to edit_project_path(@project), notice: "Połączono z trackerem — #{people.size} osób na pierwszej stronie zespołu"
  rescue IntumClient::Error => e
    redirect_to edit_project_path(@project), alert: "Test połączenia nie przeszedł: #{e.message}"
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
    # Puste pole tokena nie kasuje sekretu — niezmiennik siedzi w setterze modelu.
    params.require(:project).permit(:name, :repo_path, :repo_url, :default_claude_config, :default_model,
                                    :default_effort, :docs_path, :review_prompt_extra, :task_comment_instructions,
                                    :worktree_command, :worktree_delete_command, :task_url_prefix,
                                    :second_reviewer_default, :approve_label_default, :intum_api_token)
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
    # outward: selfreview to prywatna runda przed PR-em — jego wynik czeka na liście
    # projektu, a nie w kolejkach „co teraz kliknąć" na stronie wejściowej.
    waiting = Review.outward
                    .where(project: @main_project,
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
    # Te same sygnały co na liście review, jednym zapytaniem: „reviewing" bez
    # pracującej sesji znaczy, że job stoi w kolejce workera, a weryfikacja uwag
    # (pending też) nie zmienia statusu review, więc kafel musi o niej wiedzieć sam.
    active_runs = ClaudeRun.where(status: "running")
                           .or(ClaudeRun.where(kind: "verify_findings", status: "pending"))
                           .pluck(:review_id, :kind, :status)
    @running_review_ids = active_runs.filter_map { |review_id, _kind, run_status| review_id if run_status == "running" }.uniq
    @verifying_review_ids = active_runs.filter_map { |review_id, kind, _run_status| review_id if kind == "verify_findings" }.uniq
  end

  # Dwa zapytania GROUP BY na całą listę zamiast trzech na projekt. „czeka"
  # i „w toku" liczą tylko outward (selfreview nie woła o uwagę — patrz
  # Review.outward); „łącznie" liczy wszystko, bo tyle naprawdę jest w projekcie.
  def review_counts
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
