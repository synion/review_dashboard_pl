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
      # Sesja przebiegła poprawnie, ale komentarz nie powstał/nie wszedł — powód
      # na runie, bo stamtąd czyta go task_comment_error.
      fail_with!(review, run, match[1])
    else
      # Z tokenem trackera sesja tylko pisze treść — wysyłamy sami przez API
      # (z opcjonalnym skierowaniem do osoby drugiego sprawdzenia). Bez tokena
      # sesja wysłała komentarz sama (stara ścieżka przez skill).
      publish_via_api(review, text, intum) if review.project.intum_enabled?
      mark_ready(review, run, text)
    end
  rescue IntumClient::Error => e
    fail_with!(review, run, e.message)
  rescue StandardError
    # Decyzja już poszła na GitHub — porażka komentarza nie może jej dotknąć.
    # Treści task_comment nie ruszamy: nieudane ponowienie nie zamazuje śladu
    # poprzedniego, dodanego komentarza; powód błędu widok czyta z runa.
    review.update!(task_comment_status: "failed") if Review.exists?(review.id)
  end

  private

  def fail_with!(review, run, message)
    run.update!(error_message: message)
    review.update!(task_comment_status: "failed")
  end

  # Zapis „ready" dzieje się PO udanej wysyłce — gdy padnie sam zapis, komentarz
  # już wisi w zadaniu, a „Ponów" wysłałby go drugi raz. Stąd jawne ostrzeżenie
  # w powodzie błędu zamiast cichego "failed".
  def mark_ready(review, run, text)
    review.update!(task_comment: text, task_comment_status: "ready")
  rescue StandardError
    if review.project.intum_enabled?
      run.update!(error_message: "Komentarz ZOSTAŁ dodany do zadania, ale zapis statusu się nie powiódł — NIE ponawiaj (grozi duplikatem)")
    end
    raise
  end

  # Numer zadania z URL-a (scoped_id) → GET po PK → POST komentarza. Komentarze
  # w trackerze chodzą po PK zadania, nie po numerze widocznym w adresie.
  def publish_via_api(review, text, intum)
    intum ||= review.project.intum_client
    scoped_id = review.task_scoped_id
    raise IntumClient::Error, "nie umiem wyłuskać numeru zadania z #{review.task_url}" if scoped_id.blank?

    task_pk = intum.task(scoped_id).fetch("id")
    intum.post_comment(task_pk, text, responsible_id: review.task_comment_responsible_id)
  end
end
