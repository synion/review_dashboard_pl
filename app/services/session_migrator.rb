# Przenosi pliki sesji Claude CLI do innego katalogu configu, żeby po zmianie konta
# `claude --resume` dalej znajdował kontekst review. Kopiuje, nie przenosi —
# na starym koncie sesja ma zostać, bo przełączenie bywa odwracane.
class SessionMigrator
  def initialize(review)
    @review = review
  end

  # Zwraca liczbę skopiowanych sesji. Brak pliku źródłowego nie jest błędem:
  # sesja mogła zostać sprzątnięta poza dashboardem, a kontekst i tak dowozi prompt.
  def migrate_to(config)
    @review.claude_runs.where.not(session_id: nil).to_a.count { |run| copy(run, config) }
  end

  private

  def copy(run, config)
    source = run.session_file
    return false unless source&.exist?

    target = run.session_file(config)
    # Powrót na poprzednie konto: run został zapisany na starym configu, więc źródło
    # i cel to ten sam plik. FileUtils.cp na samym sobie rzuca ArgumentError, a sesja
    # i tak jest już tam, gdzie ma być — pominięcie jest poprawne, nie awaryjne.
    return false if target == source

    FileUtils.mkdir_p(target.dirname)
    FileUtils.cp(source, target)
    # Katalog o nazwie sesji trzyma tool-results, na które powołuje się transkrypt —
    # bez niego wznowiona sesja trafia na martwe odnośniki.
    tools = source.sub_ext("")
    FileUtils.cp_r(tools, target.dirname) if tools.directory?
    true
  end
end
