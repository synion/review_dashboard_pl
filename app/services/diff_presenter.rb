# Trzy warstwy widoku zmian w jednej strukturze: linie diffu, komentarze ludzi
# z GitHuba i znaleziska Claude'a. Kotwiczenie żyje tutaj, żeby widok tylko rysował
# to, co dostał, a testy mogły sprawdzić „co przy której linii" bez HTML-a.
#
# Same wątki składa PrDiscussion — ta sama struktura jedzie do promptów sesji,
# więc „co jest odpowiedzią na co" nie może się rozjechać między widokiem a promptem.
class DiffPresenter
  MODES = %w[unified split].freeze
  DEFAULT_MODE = "unified".freeze
  # Powyżej tego progu plik czeka na kliknięcie: kilka tysięcy wierszy tabeli na
  # plik potrafi zamulić przeglądarkę, a przy takim diffie i tak ogląda się fragmenty.
  MAX_PATCH_LINES = 1000

  UnifiedRow = Data.define(:kind, :left, :right, :text, :threads, :findings)
  SplitRow = Data.define(:left, :right, :threads, :findings)
  HunkView = Data.define(:header, :rows)
  FileView = Data.define(:filename, :previous_filename, :status, :additions, :deletions,
                         :hunks, :file_threads, :thread_count, :finding_count, :skip_reason) do
    def renderable? = skip_reason.nil?
    def renamed? = previous_filename.present? && previous_filename != filename
  end

  attr_reader :mode

  def initialize(snapshot, findings: [], mode: DEFAULT_MODE, expanded: [])
    @snapshot = snapshot
    @findings = findings.to_a
    @mode = MODES.include?(mode.to_s) ? mode.to_s : DEFAULT_MODE
    @expanded = Array(expanded)
    @discussion = PrDiscussion.new(snapshot)
  end

  def files = @files ||= @snapshot.files.map { |file| build_file(file) }

  def issue_comments = @snapshot.issue_comments

  # Wątki z plików, których nie ma w tym snapshocie (komentarz sprzed force-pusha,
  # plik wypadł ze zmiany). Nie mają gdzie usiąść, ale nie mogą zniknąć.
  def orphan_threads
    known = @snapshot.files.map { |file| file["filename"] }.to_set
    threads.reject { |thread| known.include?(thread.path) }
  end

  def unpinned_findings = @findings - pinned_findings.values.flatten

  def stats
    { files: @snapshot.files.size,
      additions: @snapshot.files.sum { |file| file["additions"].to_i },
      deletions: @snapshot.files.sum { |file| file["deletions"].to_i } }
  end

  private

  def build_file(file)
    filename = file["filename"]
    renderable = skip_reasons.fetch(filename).nil?
    hunks = renderable ? hunks_for(file) : []
    # Plik bez wyrenderowanych wierszy nie ma do czego przypiąć wątku, więc wszystkie
    # jego wątki idą pod nagłówek — inaczej znikałyby z ekranu bez śladu.
    file_threads = threads.select { |thread| thread.path == filename && (!renderable || !thread.anchored?) }
    anchored = renderable ? threads.count { |thread| thread.path == filename && thread.anchored? } : 0

    FileView.new(filename: filename, previous_filename: file["previous_filename"],
                 status: file["status"], additions: file["additions"].to_i,
                 deletions: file["deletions"].to_i, hunks: hunks, file_threads: file_threads,
                 thread_count: anchored + file_threads.size,
                 finding_count: pinned_findings.fetch(filename, []).size,
                 skip_reason: skip_reasons.fetch(filename))
  end

  # Raz na plik, nie przy każdym pytaniu: liczenie linii patcha na trzech ścieżkach
  # (renderowalność, parsowanie, widok) mieliło ten sam megabajtowy string kilka razy.
  # `count("\n")` zamiast `lines.size` — nie alokuje tablicy linii tylko po to, żeby
  # sprawdzić, ile ich jest.
  def skip_reasons
    @skip_reasons ||= @snapshot.files.to_h { |file| [ file["filename"], skip_reason(file) ] }
  end

  def skip_reason(file)
    return :no_patch if file["patch"].blank?
    return nil if @expanded.include?(file["filename"])

    :too_large if file["patch"].count("\n") + 1 > MAX_PATCH_LINES
  end

  def hunks_for(file)
    parsed_patches.fetch(file["filename"], []).map do |hunk|
      rows = @mode == "split" ? split_rows(file["filename"], hunk.lines) : unified_rows(file["filename"], hunk.lines)
      HunkView.new(header: hunk.header, rows: rows)
    end
  end

  def unified_rows(filename, lines)
    lines.map do |line|
      UnifiedRow.new(kind: line.kind, left: line.left, right: line.right, text: line.text,
                     threads: threads_at(filename, line), findings: findings_at(filename, line))
    end
  end

  # Blok n usuniętych i m dodanych linii daje min(n, m) par „zmieniono", a nadmiar
  # z dłuższej strony wiersze z pustą przeciwległą komórką. Linia kontekstowa stoi
  # po obu stronach naraz.
  def split_rows(filename, lines)
    rows = []
    deleted = []
    added = []
    flush = lambda do
      [ deleted.size, added.size ].max.times { |index| rows << [ deleted[index], added[index] ] }
      deleted = []
      added = []
    end

    lines.each do |line|
      case line.kind
      when :del then deleted << line
      when :add then added << line
      else
        flush.call
        rows << [ line, line ]
      end
    end
    flush.call

    rows.map do |left, right|
      cells = [ left, right ].compact.uniq
      SplitRow.new(left: left, right: right,
                   threads: cells.flat_map { |cell| threads_at(filename, cell) }.uniq,
                   findings: cells.flat_map { |cell| findings_at(filename, cell) }.uniq)
    end
  end

  # Linia kontekstowa istnieje po obu stronach, więc może zbierać komentarze i z LEFT,
  # i z RIGHT. Usunięta ma tylko lewą, dodana tylko prawą — klucze wychodzą same.
  def threads_at(filename, line)
    keys = []
    keys << [ "RIGHT", line.right ] if line.right
    keys << [ "LEFT", line.left ] if line.left
    keys.flat_map { |side, number| anchored_threads.fetch([ filename, side, number ], []) }
  end

  # Pinezki tylko po prawej stronie — tak samo jak przy publikacji na GitHubie:
  # znalezisko dotyczy kodu, który zostaje, nie tego, który zniknął.
  def findings_at(filename, line)
    return [] unless line.right

    findings_index.fetch([ filename, line.right ], [])
  end

  # Indeks zamiast skanu listy przy każdym wierszu: bez niego każda z tysięcy linii
  # przepytywała wszystkie znaleziska pliku, a `location_lines` to regex liczony
  # od nowa za każdym razem.
  def findings_index
    @findings_index ||= pinned_findings.each_with_object({}) do |(path, findings), index|
      findings.each { |finding| (index[[ path, finding.location_lines.last ]] ||= []) << finding }
    end
  end

  # Plik, którego nie renderujemy, zostaje w mapie z pustą listą linii: ścieżka ma się
  # dalej rozwiązywać, ale nic nie da się do niej przypiąć — więc jego znaleziska
  # same lądują na liście „bez pinezki", zamiast celować w nieistniejące wiersze.
  def parsed_patches
    @parsed_patches ||= @snapshot.files.to_h do |file|
      [ file["filename"], skip_reasons.fetch(file["filename"]).nil? ? DiffParser.parse_patch(file["patch"]) : [] ]
    end
  end

  def diff_map = @diff_map ||= PrDiffMap.from_hunks(parsed_patches)

  # Znalezisko trafia na diff tylko wtedy, gdy jego linia naprawdę tam jest —
  # ta sama reguła (i ta sama mapa), co przy wysyłce komentarzy na GitHuba.
  # Ścieżka rozwiązuje się dokładnie albo po jednoznacznym sufiksie.
  def pinned_findings
    @pinned_findings ||= @findings.each_with_object({}) do |finding, pinned|
      path = diff_map.resolve(finding.location_path)
      line = finding.location_lines&.last
      next unless path && line && diff_map.commentable?(path, line)

      (pinned[path] ||= []) << finding
    end
  end

  def threads = @discussion.threads

  def anchored_threads
    @anchored_threads ||= threads.select(&:anchored?).group_by { |thread| [ thread.path, thread.side, thread.line ] }
  end
end
