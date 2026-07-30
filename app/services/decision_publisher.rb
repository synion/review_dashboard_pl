# Wysyła decyzję na GitHub i zwraca komunikat dla usera. Cała obsługa awarii siedzi
# tu, bo wszystkie warianty kończą się tak samo: decyzja MA wylądować na PR-ze, a to,
# czy uwagi dostały pinezki przy liniach, jest kwestią formy. Pełna lista znalezisk
# jedzie w treści zbiorczej niezależnie od tego, więc żadna awaria nie gubi treści.
class DecisionPublisher
  def self.call(review, verdict:, body:, inline:, client: GithubClient.new)
    new(review, client).publish(verdict: verdict, body: body, inline: inline)
  end

  def initialize(review, client)
    @review = review
    @client = client
  end

  def publish(verdict:, body:, inline:)
    comments, note = inline ? inline_comments : [ [], "" ]
    submit(verdict, body, comments)
    "Decyzja #{verdict} wysłana na GitHub#{note}"
  rescue GithubClient::Error => e
    # Pinezki odrzucone (typowo: linia spoza diffu mimo naszej walidacji) — decyzja
    # sama w sobie jest poprawna, więc wysyłamy ją jeszcze raz bez nich.
    raise if comments.blank?

    submit(verdict, body, [])
    "Decyzja #{verdict} wysłana na GitHub — GitHub odrzucił komentarze przy liniach (#{e.message}), review poszło bez nich"
  end

  private

  # [komentarze, dopisek do komunikatu]. Brak znalezisk = nie ma po co pytać o diff.
  def inline_comments
    findings = @review.findings.order(:priority).to_a
    return [ [], "" ] if findings.empty?

    diff = @client.pr_diff(@review.pr_url, repo_dir: repo_dir)
    comments = InlineComments.build(findings, PrDiffMap.parse(diff))
    [ comments, note_for(comments, findings.size) ]
  rescue GithubClient::Error => e
    [ [], " — bez komentarzy przy liniach: nie udało się pobrać diffu (#{e.message})" ]
  end

  def submit(verdict, body, comments)
    @client.submit_review(@review.pr_url, verdict: verdict, body: body, repo_dir: repo_dir, comments: comments)
  end

  # Ile uwag dostało pinezkę, a ile zostało samą pozycją na liście — bez tego user
  # nie wie, czy patrzeć na PR-a w zakładce Files changed, czy w opisie review.
  def note_for(comments, total)
    return " — żadnej uwagi nie dało się przypiąć do linii (wszystkie są w treści zbiorczej)" if comments.empty?

    missing = total - comments.size
    " — #{comments.size} #{pluralize_uwagi(comments.size)} przy liniach" +
      (missing.positive? ? ", #{missing} bez linii (w treści zbiorczej)" : "")
  end

  # Polska odmiana: 1 uwaga, 2-4 uwagi, 5+ uwag (z wyjątkiem nastek: 12 uwag).
  def pluralize_uwagi(count)
    return "uwaga" if count == 1
    return "uwagi" if (2..4).cover?(count % 10) && !(12..14).cover?(count % 100)

    "uwag"
  end

  def repo_dir
    @review.workdir
  end
end
