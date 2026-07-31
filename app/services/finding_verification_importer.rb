# Czyta verdicts.json zapisany przez sesję weryfikującą zasadność znalezisk
# i rozkłada werdykty na znaleziska — ten sam kontrakt co FixVerificationImporter
# (plik, nie tekst odpowiedzi; wiązanie po ID, bo tytuł model parafrazuje).
class FindingVerificationImporter
  Missing = Class.new(StandardError)
  FILENAME = "verdicts.json"

  def self.call(review)
    path = review.artifacts_dir.join(FILENAME)
    raise Missing, "Sesja nie zapisała #{path} — weryfikacja niedokończona" unless File.exist?(path)

    import(review, JSON.parse(File.read(path)))
  end

  def self.import(review, data)
    by_id = review.findings.index_by(&:id)
    review.transaction do
      Array(data["verdicts"]).each do |entry|
        finding = by_id[entry["id"].to_i]
        # Nieznane ID = model wymyślił znalezisko albo pomylił review. Pomijamy
        # zamiast zgadywać: fałszywe „obalone" jest groźniejsze niż brak werdyktu.
        next unless finding && Finding::VERDICTS.include?(entry["verdict"])

        finding.update!(verdict: entry["verdict"], verdict_note: entry["note"])
      end
      review.update!(findings_verified_at: Time.current)
    end
  end
end
