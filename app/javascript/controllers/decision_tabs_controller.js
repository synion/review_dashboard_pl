import { Controller } from "@hotwired/stimulus"

// Zakładki decyzji (approve / reject / comment). Jedynym stanem jest wartość
// `active` na formularzu: jej zmiana pokazuje panel z podglądem i textareą oraz
// przycisk wysyłki tej zakładki (checklista z bramką siedzi w panelu Approve).
// Panele i textarea istnieją wszystkie naraz, więc edycja przeżywa przełączanie
// bez żadnego kopiowania treści.
//
// Wybór trzymamy w sessionStorage z tego samego powodu co zaznaczenia checklisty:
// panel review'a jest podmieniany broadcastem przy każdym zapisie review i bez tego
// zakładka wracała do sugerowanej w trakcie pisania. Serwer wpisuje sugerowaną
// zakładkę w atrybut, więc bez wpisu w pamięci zostaje ona.
export default class extends Controller {
  static targets = ["tab", "pane", "submit"]
  static values = { active: String, key: String }

  connect() {
    const saved = this.read()
    if (this.tabTargets.some((tab) => tab.dataset.verdict === saved)) this.activeValue = saved
  }

  select(event) {
    this.activeValue = event.currentTarget.dataset.verdict
    this.write(this.activeValue)
  }

  // Decyzja poszła - zakładka nie ma już czego pamiętać.
  clear(event) {
    if (event?.detail?.success === false) return

    this.write(null)
  }

  activeValueChanged() {
    this.tabTargets.forEach((tab) => tab.setAttribute("aria-selected", tab.dataset.verdict === this.activeValue))
    ;[...this.paneTargets, ...this.submitTargets].forEach((el) => { el.hidden = el.dataset.verdict !== this.activeValue })
  }

  // Tryb prywatny potrafi rzucić na samym dostępie - wtedy zostaje zakładka z serwera.
  read() {
    try {
      return sessionStorage.getItem(this.keyValue)
    } catch {
      return null
    }
  }

  write(verdict) {
    try {
      if (verdict) sessionStorage.setItem(this.keyValue, verdict)
      else sessionStorage.removeItem(this.keyValue)
    } catch {
      // bez pamięci działa samo przełączanie
    }
  }
}
