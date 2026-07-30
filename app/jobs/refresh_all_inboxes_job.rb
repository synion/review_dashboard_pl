# Wejście harmonogramu (config/recurring.yml): odświeża kolejki „czeka na Twoje
# review" wszystkich aktywnych projektów, żeby PR-y do zrecenzowania pojawiały się
# same — także wtedy, gdy nikt nie otworzył dashboardu. Bez tego jedynym triggerem
# było wejście na stronę, czyli sygnał widać dopiero, gdy się o niego zapytało.
#
# Pilnuje `inbox_stale?`, mimo że harmonogram i tak chodzi rzadko: strona przy wejściu
# odświeża po swojemu, a bez tego warunku wizyta minutę przed tikiem znaczyłaby dwa
# odpytania GitHuba pod rząd.
class RefreshAllInboxesJob < ApplicationJob
  # Odpytywanie GitHuba w tle jest decyzją właściciela maszyny, nie domyślną
  # zachowanką: świeżo pobrany dashboard nie może zacząć sam wołać `gh` co 10 minut.
  # Sprawdzamy flagę w JOBIE, nie w recurring.yml — zadanie zostaje zarejestrowane
  # w Solid Queue niezależnie od flagi, więc włączenie i wyłączenie to restart apki
  # ze zmienioną zmienną, bez edycji configu i bez sierot w tabeli recurring tasks.
  ENV_FLAG = "INBOX_SCHEDULE"
  ENABLED_VALUES = %w[1 true yes on].freeze

  def self.enabled? = ENV.fetch(ENV_FLAG, "").to_s.strip.downcase.in?(ENABLED_VALUES)

  queue_as :default

  def perform
    return unless self.class.enabled?

    Project.active.with_repo.select(&:inbox_stale?).each do |project|
      RefreshInboxJob.perform_later(project)
    end
  end
end
