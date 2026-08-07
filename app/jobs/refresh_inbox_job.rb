# Odświeża kolejkę „czeka na Twoje review" w tle. Nigdy w żądaniu: `gh search`
# plus szczegóły PR-ów to kilka sekund, a strona wejściowa ma wstawać natychmiast.
# Błędy gh obsługuje sam GithubInbox (kolejka zostaje, stempel się przesuwa).
class RefreshInboxJob < ApplicationJob
  queue_as :default

  # Wejście na stronę w trakcie trwającego odświeżania zleciłoby drugi, równoległy
  # fetch tego samego projektu: wyścig delete_all/upsertów na unikalnym indeksie
  # (project_id, pr_number) i podwójne zużycie limitu GitHuba. Klucz per projekt
  # szereguje duplikaty zamiast puszczać je naraz.
  limits_concurrency key: ->(project, **) { project.id }

  # Automat siedzi tu, a nie w GithubInbox: ten jest czytelnikiem GitHuba i pisarzem
  # kolejki, a zakładanie review to decyzja o pracy — należy do joba, który tę kolejkę
  # zamówił. Po refreshu, nie przed: automat ma patrzeć na świeży stan.
  def perform(project, inbox: GithubInbox.new)
    inbox.refresh(project)
    AutoReview.create_for_requested(project)
  end
end
