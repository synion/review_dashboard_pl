module ApplicationHelper
  # Wszystkie repo leżą w katalogu domowym, więc jego prefiks jest w każdej ścieżce
  # ten sam i tylko zjada miejsce w wąskim kafelku. Pełna ścieżka zostaje w title=.
  def project_path_label(project)
    project.repo_path.to_s.sub(/\A#{Regexp.escape(Dir.home)}/, "~")
  end

  # Wspólny format krótkiej daty na listach i kaflach: „dziś"/„wczoraj" zamiast
  # gołej daty, bo pytanie brzmi „czy to było dzisiaj", a nie „którego to było".
  # Formy polskie ręcznie — apka stoi na locale `en`.
  def short_time_label(time)
    prefix = { Date.current => "dziś", Date.yesterday => "wczoraj" }[time.to_date]
    prefix ? "#{prefix} #{time.strftime("%H:%M")}" : l(time, format: :short)
  end
end
