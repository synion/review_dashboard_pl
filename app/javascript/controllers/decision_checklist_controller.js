import { Controller } from "@hotwired/stimulus"

// Bramka Approve po stronie przeglądarki: przycisk jest wyłączony, dopóki checklista
// z zadania nie jest odhaczona w całości. Serwer sprawdza dokładnie tę samą listę
// (DecisionsController#gate_error_for po Review#task_fit_items) i zostaje ostatnim
// słowem - tu chodzi o to, żeby nie tracić kliknięcia na błąd, który widać było
// przed wysłaniem.
//
// Zaznaczenia trzymamy w sessionStorage, bo panel review'a jest podmieniany
// broadcastem przy KAŻDYM zapisie review (sesja zgodności, odświeżenie komentarzy,
// odpowiedź serwera po błędzie). Bez tego odhaczone punkty znikały w trakcie czytania.
// method: :morph tego nie załatwia: idiomorph robi syncBooleanAttribute(..., "checked"),
// czyli wprost nadpisuje zaznaczenie usera stanem z serwera.
//
// Zapisujemy tylko punkty, które user faktycznie ruszył - świeższe „✓ spełnione"
// od sesji zgodności ma wygrać z domyślnie pustym stanem sprzed jej zakończenia.
export default class extends Controller {
  static targets = ["box", "approve", "hint"]
  static values = { key: String }

  connect() {
    this.state = this.read()
    this.boxTargets.forEach((box) => {
      if (Object.hasOwn(this.state, box.name)) box.checked = this.state[box.name]
    })
    this.update()
  }

  // Akcja siedzi na .checklist, więc trafiają tu tylko checkboxy checklisty -
  // reszta pól formularza (treść decyzji, comboboxy) nie budzi bramki.
  refresh(event) {
    this.state[event.target.name] = event.target.checked
    this.write(this.state)
    this.update()
  }

  // Decyzja poszła - stan checklisty nie ma już czego przeżyć.
  clear(event) {
    if (event?.detail?.success === false) return

    this.write(null)
  }

  update() {
    const left = this.boxTargets.filter((box) => !box.checked).length
    this.approveTarget.disabled = left > 0
    this.hintTarget.hidden = left === 0
    if (left > 0) {
      this.hintTarget.textContent = `Approve odblokuje się, gdy odhaczysz całą checklistę — zostało ${left}.`
    }
  }

  // Tryb prywatny i wyłączone dane witryn potrafią rzucić na samym dostępie -
  // brak pamięci ma degradować do „stan jak z serwera", nie wywalać bramki.
  read() {
    try {
      return JSON.parse(sessionStorage.getItem(this.keyValue)) || {}
    } catch {
      return {}
    }
  }

  write(state) {
    try {
      if (state) sessionStorage.setItem(this.keyValue, JSON.stringify(state))
      else sessionStorage.removeItem(this.keyValue)
    } catch {
      // trudno - bez pamięci działa sama blokada przycisku
    }
  }
}
