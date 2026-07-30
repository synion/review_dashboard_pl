# Review Dashboard

Lokalny dashboard do code review z Claude — klikalna wersja `/rev`.

Wklejasz link do PR-a (albo do zadania), Claude robi opis, potem pełny review
w osobnym worktree, a Ty jednym kliknięciem wysyłasz **Approve / Reject / Comment**
na GitHuba — razem z komentarzami przypiętymi do linii.

---

## Szybki start

1. Sprawdź [wymagania](#wymagania) — bez `claude` i zalogowanego `gh` nie ruszysz.
2. Zainstaluj i przygotuj bazę:

   ```bash
   bin/setup
   ```

3. Wskaż swoje configi Claude:

   ```bash
   cp config/claude_configs.example.yml config/claude_configs.yml
   # i wpisz swoje katalogi configów
   ```
4. Uruchom:

   ```bash
   bin/dev            # → http://localhost:3000
   PORT=3020 bin/dev  # inny port
   ```

5. W UI: **Nowy projekt** → wypełnij formularz ([pola niżej](#konfiguracja-projektu)) → **+ Nowy review**.

> **Uwaga:** startuj przez `bin/dev`, nie `bin/rails server`. `bin/dev` ustawia
> `SOLID_QUEUE_IN_PUMA=1` — bez tego apka wstaje **bez workerów** i żaden review
> nigdy nie wystartuje.

---

## Wymagania

| Narzędzie | Po co | Jak sprawdzić |
|---|---|---|
| Ruby 3.4.7 | apka (Rails 8.1, SQLite — zero zewnętrznych baz) | `ruby -v` |
| `claude` CLI | sesje review (headless, `--output-format stream-json`) | `claude --version` |
| `gh` CLI, zalogowany | czytanie PR-ów, wysyłka decyzji (`gh pr review`, `gh api`) | `gh auth status` |
| `zsh` | komendy worktree i Playwright odpalane są przez `zsh -c` | jest w macOS |
| repo projektu ze skryptem worktree | review pracuje w izolowanym worktree, nie w Twoim repo | np. `bin/worktree-docker` |

Zalecane: `asdf` — dashboard wstawia `~/.asdf/shims` na czoło PATH subprocesów,
żeby `ruby`/`bin/rails` w repo projektu rozwiązywały się wg **jego** `.ruby-version`.

---

## Konfiguracja Claude

### 1. Katalogi configów

Lista dostępnych kont/configów Claude żyje w `config/claude_configs.yml`
(plik jest w `.gitignore` — wzór w `config/claude_configs.example.yml`):

```yaml
"etykieta widoczna w UI": /Users/ty/.claude
"drugie konto (opcjonalnie)": /Users/ty/.claude-drugi-config
```

Bez tego pliku dashboard używa jednego domyślnego configu `~/.claude`.
Wybrany config trafia do `CLAUDE_CONFIG_DIR`
spawnowanej sesji — dzięki temu możesz przełączać konta per review, a nawet
w trakcie review (przycisk „Przełącz konto" kopiuje sesję między configami).

### 2. Jak dashboard odpala Claude

```
claude -p --verbose --output-format stream-json --dangerously-skip-permissions
```

- **`--dangerously-skip-permissions`** — sesje działają bez pytań o zgodę.
  Odpalaj review tylko na repo, którym ufasz.
- **`--resume`** — followupy wracają do sesji review z pełnym kontekstem.
- **`--model` / `--effort`** — wybierane per review w UI
  (fable / opus / sonnet / haiku; low → max). Puste = domyślne z configu.

### 3. Co config Claude musi umieć

| Zdolność | Status | Do czego |
|---|---|---|
| `gh` w PATH | **wymagane** | opis PR-a (`gh pr view/diff`) robi sesja Claude, nie dashboard |
| dostęp do trackera zadań (skill / MCP) | opcjonalne | „Opis zadania" i „Komentarz do zadania" każą sesji **otworzyć `task_url`** — bez skilla do Twojego trackera te kroki skończą się błędem (review działa dalej) |
| Playwright w repo projektu | opcjonalne | obszar „QA + Playwright" pisze i odpala test klikający feature |

Żadnych innych skilli dashboard nie wymaga — prompty (w `app/prompts/`) są
samowystarczalne. Wspólny styl odpowiedzi (`_style.md`) jest wstrzykiwany do
każdego promptu; edycja działa bez restartu apki.

---

## Konfiguracja projektu

Wszystko klika się w UI (**Nowy projekt**). Pola:

| Pole | Wymagane | Opis |
|---|---|---|
| Nazwa | tak | unikalna, identyfikuje projekt na liście |
| Ścieżka repo (`repo_path`) | tak | absolutna ścieżka do repo na dysku |
| Komenda worktree | tak | np. `bin/worktree-docker %{branch}` — `%{branch}` to placeholder, literalny procent zapisz jako `%%` |
| Komenda usuwania worktree | nie | np. `bin/worktree-docker -d %{branch}` — bez niej dashboard nie posprząta worktree po usunięciu review |
| Adres repo na GitHubie | nie | pilnuje, żeby wklejony PR należał do tego projektu |
| Domyślny config / model / effort | config: tak | wartości startowe formularza nowego review |
| Prefiks adresu zadania (`task_url_prefix`) | nie | link do zadania jest wyłuskiwany z opisu PR-a i wpisywany w formularz review; puste = wyłączone |
| Katalog dokumentacji (`docs_path`) | nie (default `doc/llm`) | jeśli istnieje w repo, review czyta stamtąd konwencje projektu |
| Stałe zasady review | nie | tekst doklejany do każdego promptu review w tym projekcie |
| Instrukcja komentarza do zadania | nie | jak ma wyglądać komentarz w trackerze po decyzji |

**Kontrakt na skrypt worktree:** dostaje nazwę brancha, tworzy działający worktree
(z configami i bazą — surowy `git worktree add` nie wystarcza) i wypisuje go tak,
żeby był widoczny w `git worktree list`. Dashboard waliduje przy zapisie, czy
skrypt istnieje i czy wzorzec `%{branch}` jest poprawny.

---

## Kolejka „czeka na Twoje review"

Strona główna zaczyna się listą PR-ów, na których wisi **moje** review — to samo, co
GitHub pokazuje w „Needs your review", plus PR-y, gdzie ktoś odezwał się PO moim review:

| Sygnał | Skąd |
|---|---|
| „prosi o Twoje review" | `gh search prs --repo <repo> --state open --review-requested=@me` |
| „odezwał się po Twoim review" | `gh search prs --reviewed-by=@me` + `gh pr view` (reviews, comments) |

Dwie reguły: **własne PR-y nie wchodzą** (swojego kodu nie recenzuję; login bierze się
z `gh api user`, nie z configu) i **komentarz sam z siebie nie jest piłką** — liczy się
dopiero cudzy ruch późniejszy niż moje ostatnie review. Kolejka odświeża się przy wejściu na stronę i przyciskiem „🔄 Sprawdź teraz", a po
ustawieniu `INBOX_SCHEDULE=1` także z harmonogramu (`config/recurring.yml` →
`RefreshAllInboxesJob`, co `GithubInbox::STALE_AFTER`) — czyli bez wchodzenia tutaj; padnięte `gh`
nigdy jej nie czyści (pusty wynik wyglądałby jak „nikt nie czeka"). PR bez review
w dashboardzie prowadzi do formularza z wypełnionym `pr_url` i linkiem do zadania
wyłuskanym z opisu PR-a.

Własne PR-y nie znikają z apki — review swojego kodu zakładasz normalnie przez
**+ Nowy review**, tylko nie zaśmieca ono kolejki.

---

## Flow

1. **+ Nowy review** → wklej link do PR-a (albo do zadania, gdy PR-a nie ma) → wybierz config / model / effort.
2. Claude pisze **opis zmian** (a równolegle — jeśli jest `task_url` — opis zadania z komentarzami z trackera).
3. Zaznacz **obszary do sprawdzenia** (funkcjonalność, UX, czytelność, API, zasady projektu, QA + Playwright) → **Start review**. Review pracuje w świeżym worktree z wycheckoutowanym PR-em.
4. Wynik: podsumowanie + znaleziska (`critical` / `important` / `minor`) + opcjonalny test Playwright (**Obejrzyj** = headed ze spotlightami, **Szybka weryfikacja** = headless).
5. **Approve / Reject / Comment** → `gh pr review` z edytowalną treścią; znaleziska z linią lecą jako komentarze inline. Opcjonalnie: komentarz z decyzją do zadania w trackerze.
6. Po decyzji: **followup** (dyskusja z reviewerem, `--resume` z pełnym kontekstem), **kompaktowanie** sesji gdy kontekst puchnie, „wróć do sesji" (`claude --resume` w terminalu). Przy wejściu na listę dashboard sprawdza (max raz na godzinę per review), czy autor poprosił o ponowne review.

Artefakty każdego review (result.json, logi sesji, logi Playwright) leżą
w `storage/reviews/<id>/` i znikają razem z review.

---

## Zmienne środowiskowe

Wszystkie opcjonalne. Wzorzec w [`.env.example`](.env.example) — **Rails nie
ładuje `.env` automatycznie** (nie ma dotenv); przekazuj w shellu:
`PORT=3020 GITHUB_REVIEWER_LOGIN=twoj-login bin/dev`.

| Zmienna | Default | Opis |
|---|---|---|
| `PORT` | `3000` | port serwera |
| `GITHUB_REVIEWER_LOGIN` | login z `gh api user` | obejście: normalnie login bierze się z zalogowanego `gh` (tego samego konta, do którego rozwiązuje się `@me` w `gh search`) |
| `INBOX_SCHEDULE` | wyłączone | `1` włącza odświeżanie kolejki „czeka na Twoje review" w tle (co `GithubInbox::STALE_AFTER`); bez tego dashboard pyta GitHuba tylko przy wejściu na stronę i po kliknięciu „Sprawdź teraz" |
| `SOLID_QUEUE_IN_PUMA` | ustawia `bin/dev` | workery jobów w procesie Pumy; bez tego joby nie ruszają |
| `JOB_CONCURRENCY` | `1` | liczba procesów workerów |
| `RAILS_MAX_THREADS` | `5` | pula połączeń do SQLite |

---

## Problemy

- **Review wisi w „created" / nic nie startuje** — apka odpalona bez workerów.
  Uruchamiaj przez `bin/dev` (ustawia `SOLID_QUEUE_IN_PUMA=1`).
- **Workery nie widzą zmian w kodzie / po migracji** — forkowane procesy jobów
  nie przeładowują się same: `touch tmp/restart.txt`. Uwaga: restart ubija
  działające sesje — najpierw sprawdź, czy nic nie pracuje.
- **„no such file or directory" przy starcie review** — zła komenda worktree
  w projekcie; formularz podpowiada podobne skrypty z `bin/` przy zapisie.
- **Sesja zamilkła** — watchdog przerywa po ciszy (idle timeout) i oznacza run
  jako zawieszony; przycisk **Ponów** odpala krok od nowa.
- **„No conversation found" przy followupie** — plik sesji jest w drugim configu
  albo Claude CLI sprzątnął stare sesje; dashboard sam to wykrywa i dowozi
  kontekst w prompcie, ale najstarsze review mogą wymagać świeżego startu.
