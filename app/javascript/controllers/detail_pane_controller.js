import { Controller } from "@hotwired/stimulus"

// Podświetlenie wybranej pozycji w lewej kolumnie. Bez niego po kilku kliknięciach
// nie widać, czyje szczegóły stoją po prawej — a kafle wyglądają identycznie.
// Stan trzyma DOM (klasa is-selected), więc podmiany turbo_stream w kolejkach go
// gubią razem z kaflem, którego już nie ma — i dobrze.
const ITEM = ".qitem, .projcard, .archrow"

export default class extends Controller {
  connect() {
    this.element.addEventListener("click", this.pick)
  }

  disconnect() {
    this.element.removeEventListener("click", this.pick)
  }

  // Łapiemy klik w cokolwiek, co celuje w ramkę #detail — także w link „Zleć review",
  // nie tylko w tytuł kafla.
  pick = (event) => {
    const link = event.target.closest("a[data-turbo-frame='detail']")
    if (!link) return
    const item = link.closest(ITEM)
    this.element.querySelectorAll(`${ITEM}.is-selected`).forEach((el) => el.classList.remove("is-selected"))
    if (item) item.classList.add("is-selected")
  }
}
