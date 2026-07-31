import { Controller } from "@hotwired/stimulus"

// Combobox z podpowiedziami z lokalnego cache (endpoint /projects/:id/directory).
// Wpisywanie filtruje (debounce), klik pozycji zapisuje id do hidden fielda,
// × czyści wybór. Wartość wysyłana formularzem to zawsze hidden (id), nie tekst.
export default class extends Controller {
  static targets = ["input", "list", "hidden"]
  static values = { url: String }

  connect() {
    this.timer = null
    // Klik poza comboboxem chowa listę — bez tego wisiałaby po odejściu myszą.
    this.outsideClick = (e) => { if (!this.element.contains(e.target)) this.hide() }
    document.addEventListener("click", this.outsideClick)
  }

  disconnect() {
    document.removeEventListener("click", this.outsideClick)
  }

  search() {
    clearTimeout(this.timer)
    // Ręczna edycja tekstu unieważnia poprzedni wybór — inaczej formularz
    // wysłałby id niewidoczne już w inpucie.
    this.hiddenTarget.value = ""
    this.timer = setTimeout(() => this.fetchOptions(), 200)
  }

  async fetchOptions() {
    const q = encodeURIComponent(this.inputTarget.value)
    const response = await fetch(`${this.urlValue}&q=${q}`, { headers: { Accept: "application/json" } })
    if (!response.ok) return
    this.render(await response.json())
  }

  render(options) {
    this.listTarget.replaceChildren()
    for (const option of options) {
      const item = document.createElement("button")
      item.type = "button"
      item.className = "combobox-option"
      item.textContent = option.name
      item.addEventListener("click", () => this.select(option))
      this.listTarget.appendChild(item)
    }
    this.listTarget.hidden = options.length === 0
  }

  select(option) {
    this.hiddenTarget.value = option.id
    this.inputTarget.value = option.name
    this.hide()
  }

  clear() {
    this.hiddenTarget.value = ""
    this.inputTarget.value = ""
    this.hide()
  }

  hide() {
    this.listTarget.hidden = true
  }
}
