module ApplicationHelper
  # Wszystkie repo leżą w katalogu domowym, więc jego prefiks jest w każdej ścieżce
  # ten sam i tylko zjada miejsce w wąskim kafelku. Pełna ścieżka zostaje w title=.
  def project_path_label(project)
    project.repo_path.to_s.sub(/\A#{Regexp.escape(Dir.home)}/, "~")
  end

  # Nazwa apki w pasku kart. Trzyma się dokładnie tych samych liczb i tej samej
  # kolejności co piguły w #summary (czeka / do dokończenia / w toku) — inaczej
  # tytuł byłby czwartym licznikiem, który trzeba osobno rozszyfrować.
  DASHBOARD_TITLE_BASE = "Review Dashboard"

  # Pierwsze wejście renderuje tytuł tu, żeby był poprawny zanim wystartuje JS;
  # kolejne aktualizacje robi page_title_controller, bo kolejki zmieniają się
  # broadcastem, bez przeładowania strony. Format musi zostać ten sam w obu miejscach.
  def dashboard_title(dashboard)
    counts = [ dashboard.inbox_items.size, dashboard.attention_reviews.size,
               dashboard.in_progress_reviews.size ]
    return DASHBOARD_TITLE_BASE if counts.none?(&:positive?)

    "(#{counts.join("/")}) #{DASHBOARD_TITLE_BASE}"
  end

  # Wspólny format krótkiej daty na listach i kaflach: „dziś"/„wczoraj" zamiast
  # gołej daty, bo pytanie brzmi „czy to było dzisiaj", a nie „którego to było".
  # Formy polskie ręcznie — apka stoi na locale `en`.
  def short_time_label(time)
    prefix = { Date.current => "dziś", Date.yesterday => "wczoraj" }[time.to_date]
    prefix ? "#{prefix} #{time.strftime("%H:%M")}" : l(time, format: :short)
  end
end
