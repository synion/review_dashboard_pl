class Finding < ApplicationRecord
  PRIORITIES = %w[critical important minor].freeze
  PRIORITY_LABELS = { "critical" => "Krytyczne", "important" => "Ważne", "minor" => "Drobne" }.freeze

  # `file_location` przychodzi z result.json jako jeden string („plik.rb:214",
  # „plik.rb:12-20", czasem sama ścieżka albo ogon typu „:42 (metoda #call)").
  # Ścieżka nie może zawierać dwukropka, bo to on oddziela numer linii.
  LOCATION = /\A(?<path>[^\s:]+)(?::(?<from>\d+)(?:-(?<to>\d+))?)?/

  # Wynik weryfikacji poprawek autora. `unclear` jest osobnym stanem, nie brakiem
  # odpowiedzi: „z diffu nie wynika, czy to zaadresowane" to informacja dla człowieka.
  # nil znaczy „jeszcze nie sprawdzaliśmy".
  FIX_STATUSES = %w[implemented ignored unclear].freeze
  FIX_LABELS = { "implemented" => "✓ wdrożone", "ignored" => "✗ zignorowane",
                 "unclear" => "? niejasne" }.freeze

  belongs_to :review

  validates :priority, inclusion: { in: PRIORITIES }
  validates :title, presence: true
  validates :fix_status, inclusion: { in: FIX_STATUSES }, allow_nil: true

  def fix_label = FIX_LABELS[fix_status]

  def location_path
    location_match&.[](:path)
  end

  # Zakres linii do przypięcia komentarza na GitHubie; nil, gdy znalezisko jest ogólne.
  # Odwrócony zakres (błąd modelu) degeneruje się do pierwszej linii — GitHub wymaga
  # start_line < line i odrzuciłby całe review.
  def location_lines
    match = location_match
    from = match&.[](:from)&.to_i
    return nil unless from

    to = match[:to].to_i
    to > from ? (from..to) : (from..from)
  end

  private

  def location_match
    LOCATION.match(file_location.to_s.strip.delete_prefix("./"))
  end
end
