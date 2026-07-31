class DecisionsController < ApplicationController
  def create
    @review = Review.find(params[:review_id])
    verdict = params[:verdict]
    return render_error("Nieznana decyzja: #{verdict}") unless Review::DECISIONS.include?(verdict)
    return render_error("Ten review nie ma powiązanego PR-a — nie ma gdzie wysłać decyzji") if @review.pr_url.blank?

    body = params[:body].to_s
    notice = DecisionPublisher.call(@review, verdict: verdict, body: body, inline: params[:inline_comments] == "1")
    attrs = { status: "decided", decision: verdict, decision_body: body, decided_at: Time.current,
              decision_head_sha: head_sha_at_decision }
    # Instrukcję mrozimy na review (nawet identyczną z projektową) — „Ponów" ma
    # użyć dokładnie tej, którą user widział przy decyzji, a nie późniejszego
    # stanu projektu. Status kolejki tu, nie w jobie — patrz refresh_task_description;
    # jednym update! z decyzją, żeby panel dostał jeden broadcast.
    attrs.merge!(task_comment_status: "queued",
                 task_comment_instructions: params[:task_comment_instructions].to_s.strip.presence,
                 task_comment_responsible_id: params[:task_comment_responsible_id].presence,
                 task_comment_responsible_name: responsible_name) if comment_task?
    # Wybory akcji po decyzji mrozimy na review razem z decyzją (status queued
    # jak przy komentarzu do zadania) — „Ponów" po awarii użyje dokładnie tego,
    # co user widział, nie późniejszych defaultów.
    attrs.merge!(followup_reviewer_login: params[:followup_reviewer].presence,
                 followup_reviewer_status: params[:followup_reviewer].presence && "queued",
                 followup_label_name: params[:followup_label].presence,
                 followup_label_status: params[:followup_label].presence && "queued")
    @review.update!(attrs)
    if comment_task?
      CommentTaskJob.perform_later(@review)
      notice += ". Komentarz do zadania w kolejce"
    end
    if attrs[:followup_reviewer_status] || attrs[:followup_label_status]
      FollowupActionsJob.perform_later(@review)
      notice += ". Akcje na PR-ze (reviewer/label) w kolejce"
    end
    redirect_to review_path(@review), notice: notice
  rescue GithubClient::Error => e
    render_error(e.message)
  end

  private

  # Stan kodu, na który człowiek właśnie patrzył — bez niego późniejsze „sprawdź, czy
  # uwagi wdrożone" nie ma od czego liczyć diffu. Padnięty gh nie może wywalić wysyłki
  # decyzji, która już wyszła na GitHuba, więc błąd kończy się brakiem SHA.
  def head_sha_at_decision
    GithubClient.new.pr_head_sha(@review.pr_url, repo_dir: @review.workdir)
  rescue GithubClient::Error => e
    Rails.logger.warn("DecisionsController review #{@review.id}: #{e.message}")
    nil
  end

  # Kolejkujemy tylko na jawne życzenie i tylko, gdy jest dokąd pisać — formularz
  # bez task_url w ogóle nie pokazuje checkboxa, ale parametr można spreparować.
  def comment_task?
    params[:task_comment] == "1" && @review.task_url.present?
  end

  # Nazwa do wyświetlenia w panelu — combobox wysyła tylko id, nazwę bierzemy
  # z lokalnego cache. Brak wpisu (spreparowany id) = brak nazwy, id zostaje.
  def responsible_name
    id = params[:task_comment_responsible_id].presence
    id && @review.project.directory_entries.find_by(kind: "intum_user", external_id: id)&.name
  end

  def render_error(message)
    flash.now[:error] = message
    @body_draft = params[:body]
    render "reviews/show", status: :unprocessable_entity
  end
end
