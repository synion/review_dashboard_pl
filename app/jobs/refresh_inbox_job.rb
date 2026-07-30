# Odświeża kolejkę „czeka na Twoje review" w tle. Nigdy w żądaniu: `gh search`
# plus szczegóły PR-ów to kilka sekund, a strona wejściowa ma wstawać natychmiast.
# Błędy gh obsługuje sam GithubInbox (kolejka zostaje, stempel się przesuwa).
class RefreshInboxJob < ApplicationJob
  queue_as :default

  def perform(project, inbox: GithubInbox.new)
    inbox.refresh(project)
  end
end
