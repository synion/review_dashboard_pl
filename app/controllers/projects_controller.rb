class ProjectsController < ApplicationController
  include DashboardShell

  before_action :set_project, only: %i[edit update archive unarchive test_intum]

  def index
    refresh_on_visit
  end

  # Przełącznik projektu głównego — switcher u góry strony i radio „główny" na
  # karcie POST-ują tu to samo. Odpowiedź turbo_stream podmienia piguły, kolejki
  # i grid (żeby oba uchwyty pokazywały ten sam wybór) bez przeładowania strony.
  def select
    Project.active.find(params[:project_id]).make_main!
    respond_to do |format|
      format.turbo_stream { refresh_on_visit }
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

  # Efekty uboczne wejścia na stronę wejściową (dane do renderu dowozi DashboardShell).
  def refresh_on_visit
    refresh_stale_inboxes
    check_github_statuses
  end

  # Kolejka „czeka na Ciebie" to PR-y CZYJEGOŚ autorstwa, na których wisi moje review.
  # Renderujemy ostatni znany stan i dopiero zlecamy odświeżenie — inaczej pierwsze
  # wejście na stronę czekałoby kilka sekund na `gh`. Wynik dojedzie sam:
  # GithubInbox po przepisaniu kolejki broadcastuje kolejki na stronę wejściową.
  #
  # Odświeżanie obejmuje WSZYSTKIE aktywne projekty, nie tylko główny, żeby
  # przełączenie radia pokazywało świeży stan od razu.
  def refresh_stale_inboxes
    current_dashboard.projects.select { |project| project.repo_url.present? && project.inbox_stale? }
                     .each { |project| RefreshInboxJob.perform_later(project) }
  end

  # Ta strona jest jedynym miejscem, w które user zagląda codziennie — bez tego
  # PR zmergowany po cichu (bez mojej decyzji) wisiałby tu jako „wyślij decyzję"
  # aż do wejścia na listę review projektu. Godzinny cache jest wspólny z listą,
  # więc dwa wejścia nie znaczą dwóch wywołań gh.
  def check_github_statuses
    Review.enqueue_github_checks(Review.where(project: current_dashboard.main_project).due_for_github_check)
  end

  def project_params
    # Puste pole tokena nie kasuje sekretu — niezmiennik siedzi w setterze modelu.
    params.require(:project).permit(:name, :repo_path, :repo_url, :default_claude_config, :default_model,
                                    :default_effort, :docs_path, :review_prompt_extra, :process_rules, :task_comment_instructions,
                                    :worktree_command, :worktree_delete_command, :worktree_url_template,
                                    :task_url_prefix, :headline_mode,
                                    :second_reviewer_default, :approve_label_default, :intum_api_token,
                                    templates: MessageTemplate.families.keys.index_with { Review::DECISIONS })
  end
end
