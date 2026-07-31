module ApplicationHelper
  # Wszystkie repo leżą w katalogu domowym, więc jego prefiks jest w każdej ścieżce
  # ten sam i tylko zjada miejsce w wąskim kafelku. Pełna ścieżka zostaje w title=.
  def project_path_label(project)
    project.repo_path.to_s.sub(/\A#{Regexp.escape(Dir.home)}/, "~")
  end
end
