class ProjectsController < ApplicationController
  before_action :set_project, only: %i[edit update archive unarchive]

  def index
    @projects = Project.active.order(:name)
    @archived_projects = Project.archived.order(:name)
    @counts = review_counts
    load_inbox
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

  def project_params
    params.require(:project).permit(:name, :repo_path, :repo_url, :default_claude_config, :default_model,
                                    :default_effort, :docs_path, :review_prompt_extra, :task_comment_instructions,
                                    :worktree_command, :worktree_delete_command, :task_url_prefix)
  end

  # Kolejka „czeka na Ciebie" to PR-y CZYJEGOŚ autorstwa, na których wisi moje review.
  # Renderujemy ostatni znany stan i dopiero zlecamy odświeżenie — inaczej pierwsze
  # wejście na stronę czekałoby kilka sekund na `gh`.
  def load_inbox
    @inbox_items = InboxItem.where(project: @projects).includes(:project).by_urgency.to_a
    # Review dla tych PR-ów, żeby kafel wiedział, czy prowadzi do istniejącego review,
    # czy proponuje założenie nowego. Jedno zapytanie, nie jedno na kafel.
    @inbox_reviews = Review.where(project: @projects, pr_number: @inbox_items.map(&:pr_number))
                          .index_by { |review| [ review.project_id, review.pr_number ] }
    @inbox_checked_at = @projects.filter_map(&:inbox_checked_at).min
    @projects.select { |project| project.repo_url.present? && project.inbox_stale? }
             .each { |project| RefreshInboxJob.perform_later(project) }
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
