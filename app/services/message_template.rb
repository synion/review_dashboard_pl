require "mustache"

# Wspólny silnik szablonów wypowiedzi dashboardu (treść decyzji, komentarz przy
# linii, wiadomości followupu): Mustache bez escapowania HTML i bez partiali,
# z cache'em skompilowanych szablonów. Każda rodzina (Family) niesie domyślne
# szablony per werdykt i listę nazw do podpowiedzi w formularzu projektu.
module MessageTemplate
  # `key` to klucz w projects.templates, `label`/`hint` idą do formularza.
  Family = Data.define(:key, :label, :hint, :defaults, :placeholders)

  # Bez escapowania: treść idzie na GitHuba / do sesji jako markdown, więc `&`
  # czy `>` mają zostać sobą. Bez partiali: {{> nazwa}} czytałoby pliki z dysku.
  class Template < Mustache
    def escape(value) = value

    def partial(_name) = ""
  end

  # Parsowanie i generowanie kodu to ~95% kosztu renderu, a panel review jest
  # rysowany przy każdym broadcaście - kompilujemy raz per treść. Klucz = źródło,
  # więc edycja szablonu sama daje nowy wpis; zbiór jest mały.
  COMPILED = Concurrent::Map.new

  def self.compile(source) = COMPILED.compute_if_absent(source) { Mustache::Template.new(source) }

  # Rodziny w kolejności formularza. Metoda, nie stała: klasy serwisów ładują się
  # leniwie i same odwołują się do tego modułu.
  def self.families
    [ DecisionDraft::FAMILY, InlineComments::FAMILY, FollowupMessage::FOLLOWUP, FollowupMessage::CHALLENGE ]
      .index_by(&:key)
  end

  # Puste bloki i ręczne odstępy potrafią zostawić kilka pustych linii z rzędu -
  # markdown je zlewa, ale textarea nie.
  def self.render(source, context)
    Template.render(compile(source), context).gsub(/\n{3,}/, "\n\n").strip
  end

  # Jedyne miejsce, które wie, co jest domyślnym szablonem rodziny × werdyktu.
  def self.default(family, verdict) = families.fetch(family).defaults.fetch(verdict)

  # Szablon projektu (bez projektu - domyślny), a gdy jest zepsuty (zapisany poza
  # walidacją) - domyślny, żeby wypowiedź zawsze miała treść.
  def self.render_for(project, family, verdict, context)
    render(project ? project.template(family, verdict) : default(family, verdict), context)
  rescue Mustache::Parser::SyntaxError => e
    Rails.logger.warn("MessageTemplate #{family}/#{verdict} projektu #{project&.id}: #{first_line(e)}")
    render(default(family, verdict), context)
  end

  # Zepsuty szablon (niedomknięty blok) ma paść przy zapisie projektu, nie na
  # stronie review. nil = szablon poprawny; inaczej pierwsza linia komunikatu parsera.
  # Poza cache'em: walidacja widzi każdą pośrednią wersję z formularza, cache ma
  # trzymać tylko to, co jest renderowane.
  def self.error(source)
    Mustache::Template.new(source.to_s).tokens
    nil
  rescue Mustache::Parser::SyntaxError => e
    first_line(e)
  end

  def self.first_line(error) = error.message.lines.first.to_s.strip
end
