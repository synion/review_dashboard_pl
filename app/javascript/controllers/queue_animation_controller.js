import { Controller } from "@hotwired/stimulus"

// Kolejki zmieniają się bez udziału tej karty (odświeżenie GitHuba, joby review),
// więc kontroler odpowiada na dwa pytania: „co właśnie zniknęło" i „co zmieniło się
// samo, beze mnie".
//
// Wyjście: broadcast idzie morphem (patrz BroadcastDashboardJob), więc Turbo pyta
// o zgodę na usunięcie każdego węzła zdarzeniem turbo:before-morph-element.
// Anulujemy je, puszczamy animację i kasujemy węzeł sami.
//
// Podświetlenie: kafel nowy albo taki, któremu zmienił się data-state (stan pracy,
// nie tykający zegar „czeka 14 min"), dostaje klasę is-updated. Zdejmuje ją dopiero
// kliknięcie — po to jest: żeby po powrocie do karty widzieć, co ruszyło się samo.
//
// Wejście nowych kafli animuje sam CSS: morph tworzy dla nich świeże węzły, a stare
// zostawia w spokoju, więc animacja nie odpala się na całej liście.
export default class extends Controller {
  connect() {
    this.changed = new Set()
    // Podświetlenie musi przeżyć kolejne broadcasty: morph podmienia atrybut class
    // na ten z serwera, więc sama klasa gasła przy najbliższym sygnale. Pamięć
    // trzymamy po id kafla i nakładamy ją z powrotem po każdym morphie.
    this.updated = new Set()
    this.element.addEventListener("turbo:before-morph-element", this.beforeMorph)
    this.element.addEventListener("turbo:morph-element", this.afterMorph)
    this.element.addEventListener("click", this.seen)
    // Kafle DOPISANE przez morph nie dostają żadnego zdarzenia — obserwator jest
    // jedynym sposobem, żeby je złapać. Pierwsze wyrenderowanie strony go nie
    // budzi (węzły przychodzą w HTML), więc po F5 nic nie świeci.
    this.observer = new MutationObserver(this.watchAdded)
    this.observer.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.element.removeEventListener("turbo:before-morph-element", this.beforeMorph)
    this.element.removeEventListener("turbo:morph-element", this.afterMorph)
    this.element.removeEventListener("click", this.seen)
    this.observer.disconnect()
  }

  beforeMorph = (event) => {
    const item = event.target
    if (!(item instanceof Element) || !item.classList.contains("qitem")) return

    // Brak newElement znaczy „ten węzeł wypada" — reszta to kafle, które zostają.
    if (!event.detail.newElement) {
      this.leave(event, item)
      return
    }
    if (item.dataset.state !== event.detail.newElement.dataset?.state) this.changed.add(item)
  }

  // Klasę nakładamy PO morphie: morph podmienia atrybut class na ten z nowego HTML,
  // więc cokolwiek dopisane wcześniej i tak by zniknęło.
  afterMorph = (event) => {
    const item = event.target
    if (!(item instanceof Element) || !item.classList.contains("qitem")) return
    if (this.changed.delete(item)) this.updated.add(item.id)
    if (this.updated.has(item.id)) item.classList.add("is-updated")
  }

  watchAdded = (mutations) => {
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (!(node instanceof Element) || !node.classList.contains("qitem")) continue
        this.updated.add(node.id)
        node.classList.add("is-updated")
      }
    }
  }

  // Zobaczone: kliknięcie kafla gasi znacznik na dobre, także po kolejnych morphach.
  seen = (event) => {
    const item = event.target.closest?.(".qitem")
    if (!item) return
    this.updated.delete(item.id)
    item.classList.remove("is-updated")
  }

  leave(event, item) {
    // Drugi morph w trakcie animacji: nie przedłużamy jej w nieskończoność,
    // tylko pozwalamy Turbo dokończyć usunięcie.
    if (item.dataset.leaving) return

    event.preventDefault()
    item.dataset.leaving = "true"
    item.classList.add("is-leaving")
    item.addEventListener("animationend", () => item.remove(), { once: true })
  }
}
