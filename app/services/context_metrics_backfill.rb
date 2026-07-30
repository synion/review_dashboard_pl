# Uzupełnia metryki kontekstu dla sesji sprzed ich wprowadzenia. Liczby są w logach
# stream-json na dysku — brakowało tylko przepisania ich do bazy, więc backfill nie
# potrzebuje ani jednego wywołania Claude.
#
# Logi są per (review, kind) i dopisywane, więc jeden plik zawiera wszystkie sesje
# danego rodzaju. Rozdzielić je da się tylko po evencie `init`: sesja wznowiona przez
# `--resume` zachowuje session_id poprzedniej (review 11 ma trzy followupy i jedno
# session_id), więc po nim przypisania zrobić się nie da.
class ContextMetricsBackfill
  METRICS = %i[context_tokens context_window cache_read_tokens cache_creation_tokens].freeze
  Segment = Struct.new(*METRICS, :started_at)

  def self.call(scope = Review.all) = new(scope).call

  def initialize(scope)
    @scope = scope
  end

  # Zwraca liczbę uzupełnionych runów.
  def call
    @scope.includes(:claude_runs).sum do |review|
      review.claude_runs.group_by(&:kind).sum do |kind, runs|
        fill(runs.sort_by(&:id), segments(review.artifacts_dir.join("#{kind}.log")))
      end
    end
  end

  private

  def segments(path)
    return [] unless File.exist?(path)

    File.foreach(path).each_with_object([]) do |line, result|
      event = StreamJsonParser.parse_line(line)
      next if event.nil?

      # Log bywa ucięty od początku (rotacja, ręczne sprzątanie) — wtedy pierwszy
      # pomiar otwiera segment sam, zamiast przepaść razem z brakującym initem.
      result << Segment.new if event.type == :init || result.empty?
      absorb(result.last, event)
    end
  end

  def absorb(segment, event)
    # `init` nie niesie znacznika czasu, więc początek segmentu bierzemy z pierwszego
    # eventu, który go ma.
    segment.started_at ||= event.at
    case event.type
    when :assistant_text
      segment.context_tokens = event.context_tokens if event.context_tokens
    when :result
      segment.context_window = event.context_window if event.context_window
      segment.cache_read_tokens = event.cache_read_tokens
      segment.cache_creation_tokens = event.cache_creation_tokens
    end
  end

  # Gdy liczba segmentów zgadza się z liczbą runów, przypisanie jest jednoznaczne po
  # kolejności — i działa też dla logów bez znaczników czasu.
  #
  # Gdy się nie zgadza (log ma segmentów więcej niż runów: run skasowany albo
  # aplikacja zrestartowana w trakcie sesji), przypisujemy po czasie: segment należy
  # do runu, który wtedy działał. Segment sprzed pierwszego runu nie ma właściciela
  # i przepada — to właśnie ten osierocony. Gdy na jeden run wypada kilka segmentów,
  # wygrywa najpóźniejszy: to on niesie ostatni pomiar tego runu.
  def fill(runs, segments)
    return 0 if runs.empty? || segments.empty?
    return runs.zip(segments).count { |run, segment| apply(run, segment) } if runs.size == segments.size

    segments.each_with_object({}) { |segment, owners| (run = owner(runs, segment)) && owners[run] = segment }
            .count { |run, segment| apply(run, segment) }
  end

  def owner(runs, segment)
    return if segment.started_at.nil?

    runs.reverse.find { |run| run.started_at && run.started_at <= segment.started_at }
  end

  # update_columns, nie update!: to przepisanie liczb, które już powstały, więc nie ma
  # czego walidować ani o czym powiadamiać. Zwykły zapis wystrzeliłby broadcast karty
  # kontekstu dla każdego runu z osobna.
  def apply(run, segment)
    attrs = segment.to_h.compact.reject { |name, _| run[name].present? }
    return false if attrs.empty?

    run.update_columns(attrs)
    true
  end
end
