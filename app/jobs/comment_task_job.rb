class CommentTaskJob < ApplicationJob
  queue_as :default

  # Pierwsza linia odpowiedzi, gdy komentarza nie dało się dodać — patrz kontrakt
  # w comment_task.md.erb.
  ERROR_LINE = /\AERROR:\s*(.+)/

  def perform(review, session_factory: default_session_factory, intum: nil)
    # "running", nie od razu wynik — po restarcie OrphanedRunsCleanup odróżnia
    # "czeka w kolejce" od "pracowało i przepadło".
    review.update!(task_comment_status: "running")
    run = review.claude_runs.create!(kind: "comment_task", claude_config: review.effective_claude_config)
    text = session_factory.call(run).call(PromptBuilder.comment_task(review)).to_s.strip

    if (match = ERROR_LINE.match(text))
      # Sesja przebiegła poprawnie, ale komentarz nie wszedł (wygasła sesja trackera,
      # brak dostępu) — powód na runie, bo stamtąd czyta go task_comment_error.
      run.update!(error_message: match[1])
      review.update!(task_comment_status: "failed")
    else
      # Z tokenem trackera sesja tylko pisze treść — wysyłamy sami przez API
      # (z opcjonalnym skierowaniem do osoby drugiego sprawdzenia). Bez tokena
      # sesja wysłała komentarz sama (stara ścieżka przez skill).
      publish_via_api(review, text, intum) if review.project.intum_enabled?
      review.update!(task_comment: text, task_comment_status: "ready")
    end
  rescue IntumClient::Error => e
    run&.update!(error_message: e.message)
    review.update!(task_comment_status: "failed")
  rescue StandardError
    # Decyzja już poszła na GitHub — porażka komentarza nie może jej dotknąć.
    # Treści task_comment nie ruszamy: nieudane ponowienie nie zamazuje śladu
    # poprzedniego, dodanego komentarza; powód błędu widok czyta z runa.
    review.update!(task_comment_status: "failed") if Review.exists?(review.id)
  end

  private

  # Numer zadania z URL-a (scoped_id) → GET po PK → POST komentarza. Komentarze
  # w trackerze chodzą po PK zadania, nie po numerze widocznym w adresie.
  def publish_via_api(review, text, intum)
    project = review.project
    intum ||= IntumClient.new(base_url: project.intum_base_url, token: project.intum_api_token)
    scoped_id = review.task_url[/(\d+)(?:\D*)\z/, 1]
    raise IntumClient::Error, "nie umiem wyłuskać numeru zadania z #{review.task_url}" if scoped_id.blank?

    task_pk = intum.task(scoped_id).fetch("id")
    intum.post_comment(task_pk, text, responsible_id: review.task_comment_responsible_id.presence)
  end
end
