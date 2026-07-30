class CommentTaskJob < ApplicationJob
  queue_as :default

  # Pierwsza linia odpowiedzi, gdy komentarza nie dało się dodać — patrz kontrakt
  # w comment_task.md.erb.
  ERROR_LINE = /\AERROR:\s*(.+)/

  def perform(review, session_factory: default_session_factory)
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
      review.update!(task_comment: text, task_comment_status: "ready")
    end
  rescue StandardError
    # Decyzja już poszła na GitHub — porażka komentarza nie może jej dotknąć.
    # Treści task_comment nie ruszamy: nieudane ponowienie nie zamazuje śladu
    # poprzedniego, dodanego komentarza; powód błędu widok czyta z runa.
    review.update!(task_comment_status: "failed") if Review.exists?(review.id)
  end
end
