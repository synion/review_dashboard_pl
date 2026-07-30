# Czyta fixes.json zapisany przez sesję weryfikującą poprawki i rozkłada werdykty
# na znaleziska. Plik, nie tekst odpowiedzi — ten sam kontrakt co ReviewResultImporter.
#
# Werdykty przypisujemy po ID znaleziska, bo tytuł model potrafi sparafrazować,
# a wtedy ciche dopasowanie po nazwie trafiałoby w złe znalezisko.
class FixVerificationImporter
  Missing = Class.new(StandardError)
  FILENAME = "fixes.json"

  def self.call(review)
    path = review.artifacts_dir.join(FILENAME)
    raise Missing, "Sesja nie zapisała #{path} — weryfikacja niedokończona" unless File.exist?(path)

    import(review, JSON.parse(File.read(path)))
  end

  def self.import(review, data)
    by_id = review.findings.index_by(&:id)
    review.transaction do
      Array(data["fixes"]).each do |fix|
        finding = by_id[fix["id"].to_i]
        # Nieznane ID = model wymyślił znalezisko albo pomylił review. Pomijamy
        # zamiast zgadywać: fałszywe „wdrożone" jest groźniejsze niż brak werdyktu.
        next unless finding && Finding::FIX_STATUSES.include?(fix["status"])

        finding.update!(fix_status: fix["status"], fix_note: fix["note"])
      end
      review.update!(fixes_checked_at: Time.current)
    end
  end
end
