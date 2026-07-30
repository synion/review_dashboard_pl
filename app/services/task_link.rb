# Wyciąga link do zadania z opisu PR-a. Konwencja zespołu: każdy PR ma zadanie
# podlinkowane w opisie, więc przepisywanie go ręcznie do formularza jest robotą
# do zera.
#
# Wzorca nie zgadujemy — bierze się z `task_url_prefix` projektu. Dowolny URL byłby
# zły: w opisach są też linki do commitów, dokumentacji i innych PR-ów.
module TaskLink
  # Znaki, na których adres w opisie się kończy: markdown `[#32586](url)`, nawiasy,
  # przecinki i kropka na końcu zdania nie należą do adresu.
  TERMINATORS = %r{[\s)\]>,;"'`]}

  def self.find(text, prefix:)
    return nil if text.blank? || prefix.blank?

    match = text.to_s[/#{Regexp.escape(prefix)}(?:(?!#{TERMINATORS.source}).)+/]
    match&.sub(/\.\z/, "")&.presence
  end
end
