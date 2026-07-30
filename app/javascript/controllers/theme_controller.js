import { Controller } from "@hotwired/stimulus"

// Cykl: systemowy → jasny → ciemny → systemowy. Źródłem stanu jest data-theme
// na <html> (brak atrybutu = motyw systemowy); localStorage tylko utrwala wybór
// między wizytami — czyta go inline skrypt w <head> layoutu przed pierwszym
// malowaniem. Etykietę przycisku rysuje CSS (::after po data-theme).
const MODES = ["system", "light", "dark"]

export default class extends Controller {
  toggle() {
    const current = document.documentElement.dataset.theme || "system"
    const next = MODES[(MODES.indexOf(current) + 1) % MODES.length]
    if (next === "system") {
      localStorage.removeItem("theme")
      delete document.documentElement.dataset.theme
    } else {
      localStorage.setItem("theme", next)
      document.documentElement.dataset.theme = next
    }
  }
}
