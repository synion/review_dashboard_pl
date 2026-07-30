# Które linie PR-a da się skomentować na GitHubie. Odpowiedź siedzi w samym diffie:
# komentarz musi trafić w linię obecną w hunku, po PRAWEJ stronie (nowa wersja pliku).
# Linie usunięte mają tylko numer po lewej — komentarz do nich wymagałby `side: LEFT`,
# a review z choćby jedną złą linią GitHub odrzuca w całości (422).
class PrDiffMap
  HUNK = /\A@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/

  def self.parse(diff)
    new(scan(diff.to_s.lines))
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

  # Hunk kończymy po wyczerpaniu licznika z jego nagłówka, nie po napotkaniu linii
  # wyglądającej na nagłówek. Treść pliku bywa myląca: usunięta linia „-- foo" ma
  # w diffie postać „--- foo". Wszystko, co zostaje za licznikiem, to linie usunięte
  # („-") — a te nie zaczynają się od „+++ " ani „@@ ", więc nie mylą pętli wyżej.
  def self.scan(lines)
    files = {}
    path = nil
    index = 0

    while index < lines.size
      line = lines[index].chomp
      index += 1

      if line.start_with?("+++ ")
        target = line.delete_prefix("+++ ").strip
        # `+++ /dev/null` to plik usunięty w tym PR — nie ma go w nowej wersji,
        # więc nie ma czego komentować.
        path = target == "/dev/null" ? nil : target.sub(%r{\Ab/}, "")
        files[path] ||= Set.new if path
      elsif (hunk = HUNK.match(line))
        index = scan_hunk(lines, index, files[path], first_line: hunk[1].to_i, count: (hunk[2] || 1).to_i)
      end
    end

    files
  end
  private_class_method :scan

  # Zwraca indeks pierwszej linii za hunkiem. `numbers` jest nil dla pliku usuniętego —
  # linie i tak trzeba przejść, żeby nie wziąć ich treści za nagłówki kolejnego pliku.
  def self.scan_hunk(lines, index, numbers, first_line:, count:)
    number = first_line
    remaining = count

    while remaining.positive? && index < lines.size
      marker = lines[index][0]
      index += 1
      next if marker == "\\" # „\ No newline at end of file" nie jest linią pliku
      next if marker == "-"  # usunięta — nie istnieje po prawej stronie

      numbers&.add(number)
      number += 1
      remaining -= 1
    end

    index
  end
  private_class_method :scan_hunk
end
