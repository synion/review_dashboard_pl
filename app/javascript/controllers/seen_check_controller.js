import { Controller } from "@hotwired/stimulus"

// Odhaczanie „to już przejrzałem" — tylko dla oka, bez serwera i bez storage.
// Zbiór jest na poziomie modułu, nie instancji: broadcast podmienia kafle/wiersze
// (nowa instancja kontrolera), a ptaszek ma zostać. Przeładowanie strony go czyści.
const checked = new Set()

export default class extends Controller {
  static values = { key: String }

  connect() {
    this.element.checked = checked.has(this.keyValue)
    this.paint()
  }

  toggle() {
    this.element.checked ? checked.add(this.keyValue) : checked.delete(this.keyValue)
    // Ten sam PR bywa naraz w kolejce i na liście review — oba ptaszki idą razem.
    document.querySelectorAll(`.seen-check[data-seen-check-key-value="${CSS.escape(this.keyValue)}"]`).forEach(box => {
      box.checked = this.element.checked
      box.closest(".qitem, tr")?.classList.toggle("is-seen", box.checked)
    })
  }

  paint() {
    this.element.closest(".qitem, tr")?.classList.toggle("is-seen", this.element.checked)
  }
}
