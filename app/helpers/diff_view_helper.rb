# Unified czy split — wybór przeglądarki, nie własność review, więc siedzi
# w ciasteczku dokładnie jak układ strony wejściowej (ViewModeHelper).
module DiffViewHelper
  COOKIE = :diff_view

  def diff_view
    mode = cookies[COOKIE]
    DiffPresenter::MODES.include?(mode) ? mode : DiffPresenter::DEFAULT_MODE
  end

  def split_diff? = diff_view == "split"

  # Etykieta pliku w nagłówku: po zmianie ścieżki obie nazwy, bo „co to za plik"
  # przy samej nowej nazwie bywa zagadką.
  def diff_file_label(file)
    file.renamed? ? "#{file.previous_filename} → #{file.filename}" : file.filename
  end

  DIFF_STATUS_LABELS = { "added" => "nowy", "removed" => "usunięty", "renamed" => "przeniesiony",
                         "copied" => "skopiowany", "changed" => "zmieniony", "modified" => nil }.freeze

  def diff_status_label(status) = DIFF_STATUS_LABELS[status.to_s]

  SKIP_REASONS = { no_patch: "Plik binarny albo za duży dla GitHuba — treści nie ma w API.",
                   too_large: "Diff tego pliku ma ponad #{DiffPresenter::MAX_PATCH_LINES} linii." }.freeze

  def diff_skip_message(reason) = SKIP_REASONS[reason]

  MODE_LABELS = { "unified" => "Unified", "split" => "Split" }.freeze

  def diff_mode_label(mode) = MODE_LABELS.fetch(mode, mode)

  # Marker +/− zostaje mimo koloru tła: w trybie unified to jedyne, co odróżnia
  # linie po wklejeniu fragmentu gdzie indziej, i jedyne, co widzi daltonista.
  DIFF_MARKERS = { add: "+", del: "−", context: " " }.freeze

  def diff_marker(kind) = DIFF_MARKERS.fetch(kind, " ")

  def diff_stats_label(stats)
    "#{stats[:files]} #{pluralize_pliki(stats[:files])} · +#{stats[:additions]} −#{stats[:deletions]}"
  end

  # Polska odmiana: 1 plik, 2-4 pliki, 5+ plików (z wyjątkiem nastek: 12 plików).
  def pluralize_pliki(count)
    return "plik" if count == 1
    return "pliki" if (2..4).cover?(count % 10) && !(12..14).cover?(count % 100)

    "plików"
  end
end
