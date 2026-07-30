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

  def perform(project, inbox: GithubInbox.new)
    inbox.refresh(project)
  end
end
