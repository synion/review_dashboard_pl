class DecisionsController < ApplicationController
  def create
    @review = Review.find(params[:review_id])
    verdict = params[:verdict]
    return render_error("Nieznana decyzja: #{verdict}") unless Review::DECISIONS.include?(verdict)
    return render_error("Ten review nie ma powiązanego PR-a — nie ma gdzie wysłać decyzji") if @review.pr_url.blank?

    if (gate_error = gate_error_for(verdict))
      return render_error(gate_error)
    end

    body = bodies[verdict].to_s
    notice = DecisionPublisher.call(@review, verdict: verdict, body: body, inline: params[:inline_comments] == "1")
    attrs = { status: "decided", decision: verdict, decision_body: body, decided_at: Time.current,
              decision_head_sha: head_sha_at_decision, challenge: nil,
              decision_task_comments_count: @review.task_comments_count_now }
    attrs[:decision_checklist] = checklist_snapshot if @review.task_fit_gate?
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

  # Miękka bramka approve (C + override z A). Reject i comment przechodzą bez
  # pytań - one nie zamykają zadania. Błąd wraca formularzem z komunikatem, żeby
  # nie stracić edytowanej treści decyzji.
  def gate_error_for(verdict)
    return unless verdict == "approve" && @review.task_fit_gate?

    missing = @review.task_fit_items.map { |item| item["id"] }.reject { |id| params.dig(:checklist, id) == "1" }
    return "Odhacz każdy punkt z zadania przed approve (brakuje: #{missing.join(", ")})" if missing.any?
    return if !@review.approve_needs_override? || params[:override] == "1"

    "Zgodność z zadaniem jest #{@review.task_fit_verdict == "misses" ? "czerwona" : "niesprawdzona"} - zaznacz „Approve mimo to”, jeśli to świadoma decyzja"
  end

  # Nie tylko CO odhaczono, ale i które punkty przyszły odhaczone z wyniku sesji.
  # Bez `prefilled` z rekordu nie da się odróżnić „człowiek to sprawdził” od
  # „model powiedział ✓, a człowiek przeklikał” - a to była cała wartość snapshotu.
  def checklist_snapshot
    items = @review.task_fit_items
    checked = items.to_h { |item| [ item["id"], params.dig(:checklist, item["id"]) == "1" ] }
    checked.merge("override" => params[:override] == "1",
                  "prefilled" => items.select { |item| Review.task_fit_status_ok?(item["status"]) }.map { |item| item["id"] })
  end

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
    id && DirectoryEntry.name_for(@review.project, "intum_user", id)
  end

  # Formularz niesie trzy treści (body[approve|reject|comment]) i wysyła tę spod
  # klikniętego przycisku. Goły string zostaje dla wywołań spoza formularza (testy,
  # curl) - wtedy jest jedną treścią niezależnie od werdyktu.
  def bodies
    @bodies ||= begin
      body = params[:body]
      body.respond_to?(:to_unsafe_h) ? body.to_unsafe_h.slice(*Review::DECISIONS) : Review::DECISIONS.index_with(body.to_s)
    end
  end

  # Błąd wraca z wszystkimi trzema treściami i otwartą zakładką, z której padło
  # kliknięcie - user nie ma tracić edycji w żadnej z nich.
  def render_error(message)
    flash.now[:error] = message
    @active_verdict = params[:verdict] if Review::DECISIONS.include?(params[:verdict])
    @body_drafts = bodies if params[:body].present?
    render "reviews/show", status: :unprocessable_entity
  end
end
