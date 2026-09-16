# Zamienia znaleziska na komentarze przypięte do linii w payloadzie GitHuba.
# Przepuszcza tylko to, co PrDiffMap potwierdzi jako komentowalne — znalezisko bez
# pinezki nie ginie, bo pełna lista jedzie i tak w treści zbiorczej review.
class InlineComments
  MARKS = { "critical" => "🔴", "important" => "🟠", "minor" => "⚪" }.freeze
  SIDE = "RIGHT" # komentujemy nową wersję pliku; lewa strona to linie usunięte

  # Treść pod nagłówkiem pinezki, per werdykt: przy approve ta sama uwaga jest
  # nieblokująca, przy comment - pytaniem; reject zostaje gołą treścią znaleziska.
  # Sam nagłówek (pierwsza linia) jest poza szablonem - patrz header_for.
  DEFAULT_TEMPLATES = {
    "approve" => "_Uwaga nieblokująca - nie wstrzymuje merge'a, zostawiam do rozważenia._\n\n{{body}}",
    "reject" => "{{body}}",
    "comment" => "_Bez werdyktu - chcę poznać Twoje zdanie, zanim zdecyduję._\n\n{{body}}"
  }.freeze
  PLACEHOLDERS = {
    "body" => "treść znaleziska (problem, konsekwencja, poprawka)",
    "title" => "tytuł znaleziska", "priority" => "priorytet (Krytyczne / Ważne / Drobne)",
    "file" => "ścieżka pliku", "line" => "numer linii"
  }.freeze
  FAMILY = MessageTemplate::Family.new(
    key: "inline_comment", label: "Komentarz przy linii kodu na GitHub",
    hint: "Pierwsza linia pinezki (priorytet i tytuł) jest stała - po niej dashboard rozpoznaje własne komentarze na PR-ze. Szablon to reszta.",
    defaults: DEFAULT_TEMPLATES, placeholders: PLACEHOLDERS
  )

  # Bez projektu (testy, wywołania spoza decyzji) obowiązują szablony domyślne.
  def self.build(findings, diff_map, verdict: "reject", project: nil)
    findings.filter_map { |finding| comment_for(finding, diff_map, verdict, project) }
  end

  def self.comment_for(finding, diff_map, verdict, project)
    path = diff_map.resolve(finding.location_path)
    lines = finding.location_lines
    return nil unless path && lines && diff_map.commentable?(path, lines.last)

    { path: path, line: lines.last, side: SIDE, body: body_for(finding, lines.last, verdict, project) }
      .merge(range_for(lines, path, diff_map))
  end
  private_class_method :comment_for

  # Komentarz wielolinijkowy tylko wtedy, gdy CAŁY zakres jest w diffie — GitHub
  # odrzuca review, w którym start_line wypada poza hunkiem. Zakres wystający poza
  # zmienione linie zwija się do jednej pinezki zamiast przepaść.
  def self.range_for(lines, path, diff_map)
    return {} if lines.first >= lines.last
    return {} unless lines.all? { |line| diff_map.commentable?(path, line) }

    { start_line: lines.first, start_side: SIDE }
  end
  private_class_method :range_for

  # Pierwsza linia komentarza — priorytet i tytuł znaleziska. Publiczna, bo po niej
  # PrDiscussion poznaje na PR-ze WŁASNE pinezki i wiąże wątek ze znaleziskiem:
  # GitHub przy publikacji review nie zwraca id utworzonych komentarzy, więc treść
  # jest jedynym kluczem — i jedynym, który działa też wstecz.
  def self.header_for(finding)
    "#{MARKS[finding.priority]} **#{Finding::PRIORITY_LABELS[finding.priority]} — #{finding.title}**"
  end

  def self.body_for(finding, line, verdict, project)
    context = { body: finding.body.to_s.strip, title: finding.title, priority: Finding::PRIORITY_LABELS[finding.priority],
                file: finding.location_path, line: line }
    "#{header_for(finding)}\n\n#{MessageTemplate.render_for(project, "inline_comment", verdict, context)}"
  end
  private_class_method :body_for
end
