import { Controller } from "@hotwired/stimulus"

// Tytuł karty jako licznik pracy: „(1/2/3) Review Dashboard" = czeka / do dokończenia
// / w toku. Dashboard bywa otwarty w tle godzinami, a kolejki zmieniają się same
// (odświeżenie GitHuba, joby review) — bez tego jedyny sposób, żeby zobaczyć nowy
// PR, to przełączyć się na kartę.
//
// Dwa wejścia, bo kolejki przyjeżdżają dwiema drogami: pierwszy render strony
// (connect) i broadcast morphem, który zostawia ten sam węzeł i tylko podmienia
// atrybuty — wtedy connect już nie zadziała, a *ValueChanged owszem.
export default class extends Controller {
  static values = { waiting: Number, unfinished: Number, running: Number, base: String }

  connect() {
    this.apply()
  }

  waitingValueChanged() {
    this.apply()
  }

  unfinishedValueChanged() {
    this.apply()
  }

  runningValueChanged() {
    this.apply()
  }

  apply() {
    const counts = [this.waitingValue, this.unfinishedValue, this.runningValue]
    const base = this.baseValue || "Review Dashboard"
    // Same zera to „nie ma nic do roboty" — prefiks (0/0/0) byłby wtedy szumem
    // w pasku kart, a nie sygnałem.
    document.title = counts.some((count) => count > 0) ? `(${counts.join("/")}) ${base}` : base
  }
}
