# Zamienia znaleziska na komentarze przypięte do linii w payloadzie GitHuba.
# Przepuszcza tylko to, co PrDiffMap potwierdzi jako komentowalne — znalezisko bez
# pinezki nie ginie, bo pełna lista jedzie i tak w treści zbiorczej review.
class InlineComments
  MARKS = { "critical" => "🔴", "important" => "🟠", "minor" => "⚪" }.freeze
  SIDE = "RIGHT" # komentujemy nową wersję pliku; lewa strona to linie usunięte

  def self.build(findings, diff_map)
    findings.filter_map { |finding| comment_for(finding, diff_map) }
  end

  def self.comment_for(finding, diff_map)
    path = diff_map.resolve(finding.location_path)
    lines = finding.location_lines
    return nil unless path && lines && diff_map.commentable?(path, lines.last)

    { path: path, line: lines.last, side: SIDE, body: body_for(finding) }
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

  def self.body_for(finding)
    "#{MARKS[finding.priority]} **#{Finding::PRIORITY_LABELS[finding.priority]} — #{finding.title}**\n\n#{finding.body}"
  end
  private_class_method :body_for
end
