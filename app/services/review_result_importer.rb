# Czyta result.json zapisany przez sesję review i mapuje go na rekordy.
# Parsujemy plik, nie tekst odpowiedzi modelu — odporniejsze na „gadanie".
# Surowy JSON ląduje też w kolumnie raw_result — kopia w SQLite na wypadek
# zniknięcia katalogu artefaktów.
class ReviewResultImporter
  Missing = Class.new(StandardError)

  # `written_after`: start sesji, której wynik czytamy. result.json poprzedniego
  # przebiegu zostaje na dysku (followup go czyta), więc sama obecność pliku nie
  # dowodzi, że ta sesja go zapisała — bez tego ponowione review, które nic nie
  # zapisało, „kończyło się" starymi znaleziskami. Próg w pełnych sekundach, bo
  # część systemów plików trzyma mtime z sekundową dokładnością.
  def self.call(review, written_after: nil)
    path = review.artifacts_dir.join("result.json")
    raise Missing, "Sesja nie zapisała #{path} — review niedokończony" unless File.exist?(path)
    if written_after && File.mtime(path) < written_after.floor
      raise Missing, "Sesja nie zapisała nowego #{path} — na dysku jest wynik poprzedniego przebiegu"
    end

    raw = File.read(path)
    import(review, JSON.parse(raw), raw: raw)
  end

  # Import z bazy (raw_result) — gdy pliku już nie ma.
  def self.from_raw_result(review)
    raise Missing, "Brak wyniku w bazie" if review.raw_result.blank?

    import(review, JSON.parse(review.raw_result), raw: review.raw_result)
  end

  def self.import(review, data, raw:)
    review.transaction do
      # Tylko własne: znaleziska bramki zgodności (source task_fit) ma prawo kasować
      # wyłącznie TaskFitImporter, inaczej followup zdejmowałby czerwone światło z AC.
      review.findings.from_review.destroy_all
      Array(data["findings"]).each do |f|
        review.findings.create!(priority: f["priority"], title: f["title"], body: f["body"], file_location: f["file"])
      end
      review.update!(
        summary: data["summary"],
        raw_result: raw,
        playwright_test_path: data.dig("playwright", "test_path"),
        playwright_command: data.dig("playwright", "command")
      )
    end
  end
end
