class ProjectsController < ApplicationController
  before_action :set_project, only: %i[edit update archive unarchive]

  def index
    @projects = Project.active.order(:name)
    @archived_projects = Project.archived.order(:name)
    @counts = review_counts
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
                                    :worktree_command, :worktree_delete_command)
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
