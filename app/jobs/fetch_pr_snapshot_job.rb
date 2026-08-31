# Pobiera stan PR-a z GitHuba (pliki + komentarze) do artefaktu review. Zlecany
# przez podstronę zmian, gdy artefaktu nie ma albo zestarzał się względem ruchu
# na PR-ze — trzy spawny `gh` nie mogą blokować requestu.
class FetchPrSnapshotJob < ApplicationJob
  queue_as :default
  # Trzy równoległe pobrania pisałyby po tym samym pliku artefaktu.
  limits_concurrency key: ->(review, **) { review.id }

  # Komunikat błędu w cache, nie w kolumnie: to stan chwilowy („gh nie odpowiedział"),
  # a nie fakt o review. Wygasa sam, więc nikt nie ogląda wczorajszej awarii.
  ERROR_TTL = 30.minutes
  # Marker „job już leci" — F5 w trakcie pobierania nie mnoży spawnów gh.
  MARKER_TTL = 5.minutes

  def self.error_key(review) = "pr_snapshot_error_#{review.id}"
  def self.marker_key(review) = "pr_snapshot_fetch_#{review.id}"

  # Jedyne wejście dla kontrolera: kolejkuje najwyżej jeden job na review.
  # `force` to przycisk „odśwież" — świadome kliknięcie bije marker.
  def self.enqueue(review, force: false)
    Rails.cache.delete(marker_key(review)) if force
    Rails.cache.fetch(marker_key(review), expires_in: MARKER_TTL) do
      perform_later(review)
      true
    end
  end

  def perform(review, client: GithubClient.new)
    return if review.pr_url.blank?

    PrSnapshot.fetch!(review, client: client)
    Rails.cache.delete(self.class.error_key(review))
  rescue GithubClient::Error => e
    Rails.cache.write(self.class.error_key(review), e.message, expires_in: ERROR_TTL)
  ensure
    Rails.cache.delete(self.class.marker_key(review))
    # Refresh, nie podmiana fragmentu: tryb widoku (unified/split) i rozwinięte pliki
    # siedzą w ciasteczku i parametrach przeglądarki, których job nie zna. Turbo
    # przeładuje stronę tak, jak ogląda ją człowiek. Osobny stream niż panel review,
    # żeby pobranie diffu nie przeładowywało otwartej strony review.
    Turbo::StreamsChannel.broadcast_refresh_to(review, :diff) if review.pr_url.present?
  end
end
