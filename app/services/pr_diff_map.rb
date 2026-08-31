# Które linie PR-a da się skomentować na GitHubie. Odpowiedź siedzi w samym diffie:
# komentarz musi trafić w linię obecną w hunku, po PRAWEJ stronie (nowa wersja pliku).
# Linie usunięte mają tylko numer po lewej — komentarz do nich wymagałby `side: LEFT`,
# a review z choćby jedną złą linią GitHub odrzuca w całości (422).
class PrDiffMap
  # Struktura diffu przychodzi z DiffParser; tutaj zostaje z niej tylko to, o co
  # pyta publikacja: zbiór numerów linii po prawej stronie. Linie usunięte mają
  # `right` puste, więc odpadają same.
  def self.parse(diff)
    new(DiffParser.parse(diff).transform_values { |hunks|
      hunks.flat_map { |hunk| hunk.lines.filter_map(&:right) }.to_set
    })
  end

  def initialize(files)
    @files = files
  end

  # Ścieżka tak, jak zapisał ją diff — taka musi trafić do payloadu GitHuba.
  # Model bywa, że poda ją skróconą („models/invoice.rb"), więc gdy dokładne
  # dopasowanie zawiedzie, próbujemy sufiksu — ale tylko jednoznacznego.
  def resolve(path)
    clean = path.to_s.strip.delete_prefix("./")
    return nil if clean.empty?
    return clean if @files.key?(clean)

    matches = @files.keys.select { |known| known.end_with?("/#{clean}") }
    matches.size == 1 ? matches.first : nil
  end

  def commentable?(path, line)
    resolved = resolve(path)
    resolved.present? && @files.fetch(resolved).include?(line)
  end
end
