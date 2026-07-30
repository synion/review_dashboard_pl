# Wejście harmonogramu (config/recurring.yml): odświeża kolejki „czeka na Twoje
# review" wszystkich aktywnych projektów, żeby PR-y do zrecenzowania pojawiały się
# same — także wtedy, gdy nikt nie otworzył dashboardu. Bez tego jedynym triggerem
# było wejście na stronę, czyli sygnał widać dopiero, gdy się o niego zapytało.
#
# Pilnuje `inbox_stale?`, mimo że harmonogram i tak chodzi rzadko: strona przy wejściu
# odświeża po swojemu, a bez tego warunku wizyta minutę przed tikiem znaczyłaby dwa
# odpytania GitHuba pod rząd.
class RefreshAllInboxesJob < ApplicationJob
  queue_as :default

  def perform
    Project.active.with_repo.select(&:inbox_stale?).each do |project|
      RefreshInboxJob.perform_later(project)
    end
  end
end
