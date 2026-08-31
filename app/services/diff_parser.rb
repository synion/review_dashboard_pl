# Unified diff → struktura do wyświetlenia: pliki, hunki, linie z numerami po obu
# stronach. Jedyny parser diffu w apce — korzysta z niego zarówno widok zmian
# (renderuje linie), jak i PrDiffMap (pyta, które linie da się skomentować).
#
# Dwa wejścia, bo dwa źródła: `patch` z REST API GitHuba jest per plik i zaczyna się
# od razu hunkiem, a `gh pr diff` zwraca cały diff z nagłówkami plików.
class DiffParser
  HUNK = /\A@@ -(?<left>\d+)(?:,(?<left_count>\d+))? \+(?<right>\d+)(?:,(?<right_count>\d+))? @@/

  # kind: :context (linia w obu wersjach), :add (tylko nowa), :del (tylko stara).
  # left/right to numery linii — nil po stronie, w której linii nie ma.
  Line = Data.define(:kind, :left, :right, :text)
  Hunk = Data.define(:header, :lines)

  def self.parse_patch(patch)
    lines = patch.to_s.lines
    hunks = []
    index = 0

    while index < lines.size
      header = lines[index].chomp
      index += 1
      next unless (match = HUNK.match(header))

      body, index = scan_hunk(lines, index, match)
      hunks << Hunk.new(header: header, lines: body)
    end

    hunks
  end

  # Pełny diff → { "ścieżka" => [Hunk] }. Ścieżkę bierzemy z `+++ b/…`, czyli z NOWEJ
  # wersji pliku: `+++ /dev/null` to plik usunięty w tym PR-ze i wypada z mapy, bo nie
  # ma go w wersji, którą się ogląda i komentuje.
  # Plik bez hunków (sam rename, zmiana uprawnień) zostaje z pustą listą — ścieżka
  # dalej ma się rozwiązywać.
  def self.parse(diff)
    lines = diff.to_s.lines
    files = {}
    path = nil
    index = 0

    while index < lines.size
      line = lines[index].chomp
      index += 1

      if line.start_with?("+++ ")
        target = line.delete_prefix("+++ ").strip
        path = target == "/dev/null" ? nil : target.sub(%r{\Ab/}, "")
        files[path] ||= [] if path
      elsif (match = HUNK.match(line))
        body, index = scan_hunk(lines, index, match)
        files[path] << Hunk.new(header: line, lines: body) if path
      end
    end

    files
  end

  # Zwraca linie hunka i indeks pierwszej linii za nim. Koniec wyznaczają liczniki
  # z nagłówka, nie linia wyglądająca na nagłówek: usunięta linia „-- foo" ma
  # w diffie postać „--- foo" i inaczej urywałaby plik w połowie.
  def self.scan_hunk(lines, index, match)
    left = match[:left].to_i
    right = match[:right].to_i
    left_left = (match[:left_count] || 1).to_i
    right_left = (match[:right_count] || 1).to_i
    body = []

    while (left_left.positive? || right_left.positive?) && index < lines.size
      raw = lines[index].chomp
      index += 1
      next if raw.start_with?("\\") # „\ No newline at end of file" nie jest linią pliku

      text = raw[1..].to_s
      case raw[0]
      when "+"
        body << Line.new(kind: :add, left: nil, right: right, text: text)
        right += 1
        right_left -= 1
      when "-"
        body << Line.new(kind: :del, left: left, right: nil, text: text)
        left += 1
        left_left -= 1
      else
        # Pusta linia kontekstowa bywa zapisana bez wiodącej spacji — stąd `else`
        # zamiast `when " "`, inaczej urywałaby hunk w połowie.
        body << Line.new(kind: :context, left: left, right: right, text: text)
        left += 1
        right += 1
        left_left -= 1
        right_left -= 1
      end
    end

    [ body, index ]
  end
  private_class_method :scan_hunk
end
