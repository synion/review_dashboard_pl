class DescribeTaskJob < ApplicationJob
  queue_as :default

  # Pierwsza linia odpowiedzi sesji — patrz kontrakt w describe_task.md.erb.
  TASK_URL_LINE = /\ATASK_URL:\s*(\S+)/

  def perform(review, session_factory: default_session_factory)
    # "running", nie od razu wynik: to samo, co created→describing w cyklu review —
    # po restarcie OrphanedRunsCleanup odróżnia "czeka w kolejce" od "pracowało i przepadło".
    review.update!(task_description_status: "running")
    run = review.claude_runs.create!(kind: "describe_task", claude_config: review.effective_claude_config)
    text = session_factory.call(run).call(PromptBuilder.describe_task(review))
    url, body = split_task_url(text.to_s)
    attrs = { task_description: body, task_description_status: "ready" }
    attrs[:task_url] = url if review.task_url.blank? && url.present?
    review.update!(attrs)
  rescue StandardError => e
    # Osobny cykl życia: porażka opisu zadania nie kładzie review (opis zmian i review
    # idą dalej). Treści nie ruszamy — nieudane odświeżenie nie może zamazać dobrego
    # opisu; powód błędu widok czyta z runa (task_description_error).
    review.update!(task_description_status: "failed") if Review.exists?(review.id)
  end

  private

  # Czysta funkcja: [url | nil, opis]. Brak linii kontraktu = miękka degradacja —
  # cała odpowiedź idzie do opisu. "none" znaczy "szukałem, nie ma" i nie jest adresem.
  def split_task_url(text)
    match = TASK_URL_LINE.match(text)
    return [ nil, text ] unless match

    url = match[1] == "none" ? nil : match[1]
    [ url, match.post_match.lstrip ]
  end
end
