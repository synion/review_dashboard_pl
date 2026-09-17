# Dwa tryby strony wejściowej, bo to kwestia nawyku, a nie prawdy: „split" trzyma
# listę po lewej i szczegóły po prawej, „classic" wraca do jednej kolumny, w której
# kliknięcie kafla otwiera pełną stronę. Wybór siedzi w ciasteczku, nie w bazie —
# to ustawienie tej przeglądarki, tak samo jak motyw.
module ViewModeHelper
  MODES = %w[split classic].freeze
  DEFAULT_MODE = "split".freeze
  COOKIE = :view_mode

  def view_mode
    mode = cookies[COOKIE]
    MODES.include?(mode) ? mode : DEFAULT_MODE
  end

  def split_view? = view_mode == "split"

  # Cel nawigacji dla kafli i linków projektów. W trybie klasycznym nil, bo brak
  # atrybutu data-turbo-frame to zwykłe przejście na pełną stronę — dokładnie to,
  # co ten tryb obiecuje.
  def detail_frame = split_view? ? "detail" : nil

  # Podpowiedź pod kursorem musi mówić prawdę o AKTUALNYM trybie — „otwiera się
  # w prawym panelu" na jednokolumnowym układzie to instrukcja do nieistniejącego
  # panelu.
  def opens_hint(what) = split_view? ? "Otwiera #{what} w prawym panelu" : "Otwiera #{what} na osobnej stronie"

  # Treść prawego panelu (lista review, review, nowy review) w trzech wcieleniach.
  # Zapytanie z ramki dostaje samą ramkę. Pełny adres w dwóch kolumnach — dashboard
  # z tą treścią w panelu, żeby F5 i „wstecz" nie wypadały z układu. Pełny adres
  # w układzie klasycznym — gołą treść: ramka poza panelem zmieniałaby przy kliknięciu
  # tylko siebie, a adres w przeglądarce zostawałby stary.
  def detail_page(&)
    if turbo_frame_request?
      turbo_frame_tag("detail", &)
    elsif split_view?
      render(layout: "projects/dashboard", &)
    else
      capture(&)
    end
  end
end
