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
| dostęp do trackera zadań (skill / MCP) | opcjonalne | „Opis zadania" i „Komentarz do zadania" każą sesji **otworzyć `task_url`** — bez skilla do Twojego trackera te kroki skończą się błędem (review działa dalej). Wyjątek: projekt z tokenem integracji (Intum) — wtedy komentarz **wysyła aplikacja przez API**, a sesja tylko pisze jego treść |
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
| API token trackera (`intum_api_token`) | nie | włącza integrację z trackerem (Intum): komentarz po decyzji idzie bezpośrednio z aplikacji (bez sesji Claude) i można go skierować do osoby drugiego sprawdzenia; przycisk „Testuj połączenie" sprawdza token i uprawnienia. Szyfrowany w bazie |
| Domyślny drugi reviewer / label po decyzji | nie | prefille comboboxów akcji na PR-ze po decyzji (reviewer gdy nikt nie reviewował, label gdy ktoś już tak) |

**Kontrakt na skrypt worktree:** dostaje nazwę brancha, tworzy działający worktree
(z configami i bazą — surowy `git worktree add` nie wystarcza) i wypisuje go tak,
żeby był widoczny w `git worktree list`. Dashboard waliduje przy zapisie, czy
skrypt istnieje i czy wzorzec `%{branch}` jest poprawny.

---

## Akcje po decyzji i integracja z trackerem

Po wysłaniu decyzji dashboard umie zrobić za Ciebie trzy rzeczy, które dotąd
klikało się ręcznie:

| Akcja | Kiedy się przydaje | Skąd podpowiedzi |
|---|---|---|
| **Dodaj reviewera do PR-a** | nikt jeszcze nie reviewował, a wymagane jest drugie oko | collaboratorzy repo (GitHub) |
| **Dodaj label na PR** | oznaczasz stan po review (np. `after-review`) | labelki repo (GitHub) |
| **Skieruj komentarz w zadaniu do osoby** | drugie sprawdzenie — osoba dostaje komentarz z decyzją przypisany do siebie (responsible KOMENTARZA, nigdy całego zadania) | zespół z trackera (Intum) |

Wszystkie trzy wybiera się comboboxami na panelu decyzji (wpisujesz fragment —
filtruje lokalny cache, zero czekania). Panel pokazuje też, **kto już reviewował
PR-a** (ostatni werdykt per osoba). Akcje idą w tle po wysłanej decyzji — ich
awaria nigdy nie cofa decyzji; status i przycisk „Ponów" są na karcie decyzji.

### Jak skonfigurować (raz na projekt, ~5 minut)

1. **Świeża instalacja repo?** Wygeneruj własne klucze szyfrowania (token trackera
   jest szyfrowany w bazie): `rm config/credentials.yml.enc`, potem
   `bin/rails credentials:edit` i wklej wynik `bin/rails db:encryption:init`.
   Istniejąca instalacja z działającym `config/master.key` ma to już za sobą —
   **zrób backup `master.key`**, bez niego tokeny w bazie są nie do odzyskania.
2. **Prefiks adresu zadania** w ustawieniach projektu (np.
   `https://twoj-tracker.example.com/organize/tasks/`) — z niego brany jest host API.
3. **Token API trackera**: wygeneruj w trackerze pod `/account/api_tokens/new`,
   zaznacz uprawnienia `users, users/admin, user_settings, user_settings/all,
   user_settings/admin, tasks, projects, notifications, comments_edit`
   (pułapka: listę osób odblokowuje `user_settings`, nie samo `users`).
   Wklej w pole „API token trackera" — pole pokazuje maskowany podgląd
   (`i••••••••S5`), puste przy zapisie znaczy „bez zmian".
4. Kliknij **„🔌 Testuj połączenie"** — powinno pokazać liczbę osób w zespole.
5. Kliknij **„↻ Odśwież listy podpowiedzi"** — zaciąga collaboratorów i labelki
   z GH oraz zespół z trackera do lokalnego cache (`directory_entries`).
   Potem odświeża się samo, gdy cache jest starszy niż 12 h.
6. Opcjonalnie ustaw **domyślnego drugiego reviewera** i **domyślny label** —
   będą się podpowiadać same (reviewer, gdy PR-a nikt nie reviewował; label,
   gdy ktoś już tak).

### Po co token, skoro był skill

Z tokenem komentarz do zadania po decyzji **wysyła aplikacja jednym requestem
HTTP** — sesja Claude tylko pisze treść. Szybciej, taniej (mniej tokenów LLM)
i bez kruchego cookie sesyjnego. **Bez tokena wszystko działa jak dotychczas**:
sesja Claude wysyła komentarz sama przez skill trackera; comboboxy GitHubowe
(reviewer/label) działają niezależnie od tokena — wymagają tylko zalogowanego `gh`.

---

## Strona wejściowa

`/` odpowiada na jedno pytanie: **czyj kod muszę zrecenzować**.

| Sekcja | Co w niej jest | Skąd |
|---|---|---|
| **Czeka na Twoje review** | PR-y, w których GitHub prosi o moje review, oraz te, gdzie ktoś odezwał się PO moim review | `gh search prs --review-requested=@me` i `--reviewed-by=@me` + `gh pr view` (aktywność ludzi) |
| **Rozpoczęte w dashboardzie** | opis gotowy do odpalenia, review do wysłania, padnięta sesja | statusy `Review` |
| **W toku** | sesje Claude, przy których nic się nie klika | statusy `Review` |
| **Projekty** | liczniki i wejście do „+ Nowy review" | baza |

Dwie reguły kolejki z GitHuba: **własne PR-y nie wchodzą** (swojego kodu nie recenzuję;
login bierze się z `gh api user`, nie z configu) i **komentarz sam z siebie nie liczy się
jako piłka** — dopiero cudzy ruch późniejszy niż moje ostatnie review. Kolejka odświeża
się przy wejściu na stronę co `GithubInbox::STALE_AFTER` (1 h) i przyciskiem
„🔄 Sprawdź teraz", a po ustawieniu `INBOX_SCHEDULE=1` także z harmonogramu
(`config/recurring.yml` → `RefreshAllInboxesJob`) — czyli bez wchodzenia tutaj;
padnięte `gh` nigdy jej nie czyści (pusty wynik wyglądałby jak „nikt nie czeka").
Kafel PR-a bez review w dashboardzie prowadzi do formularza z wypełnionym `pr_url`
i linkiem do zadania wyłuskanym z opisu PR-a.

Własne PR-y nie znikają z apki — review swojego kodu zakładasz normalnie przez
**+ Nowy review**, tylko nie zaśmieca ono kolejki „czeka na Twoje review".

---

## Flow

1. **+ Nowy review** → wklej link do PR-a (albo do zadania, gdy PR-a nie ma) → wybierz config / model / effort.
2. Claude pisze **opis zmian** (a równolegle — jeśli jest `task_url` — opis zadania z komentarzami z trackera).
3. Zaznacz **obszary do sprawdzenia** (funkcjonalność, UX, czytelność, API, zasady projektu, QA + Playwright) → **Start review**. Review pracuje w świeżym worktree z wycheckoutowanym PR-em.
4. Wynik: podsumowanie + znaleziska (`critical` / `important` / `minor`) + opcjonalny test Playwright (**Obejrzyj** = headed ze spotlightami, **Szybka weryfikacja** = headless).
5. **Approve / Reject / Comment** → `gh pr review` z edytowalną treścią; znaleziska z linią lecą jako komentarze inline. Opcjonalnie: komentarz z decyzją do zadania w trackerze (z tokenem integracji — wysyłany przez API, z możliwym skierowaniem do osoby drugiego sprawdzenia), dodanie drugiego reviewera lub labela na PR (comboboxy z podpowiedziami).
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

## Trzymanie apki uruchomionej (opcjonalne, macOS)

Domyślnie dashboard żyje tyle, ile `bin/dev` w terminalu. `bin/autostart` instaluje
agenta launchd, który startuje go przy logowaniu i podnosi po padzie:

```bash
bin/autostart install --port 3020   # apka wstaje sama na tym porcie
bin/autostart install --schedule    # dodatkowo INBOX_SCHEDULE=1 (kolejka odświeża się w tle)
bin/autostart status
bin/autostart uninstall
```

Nic nie instaluje się samo: ani `bin/setup`, ani pierwsze uruchomienie nie tykają
launchd — o tym, co chodzi w tle na Twojej maszynie, decydujesz jawną komendą.

Plist jest **generowany z Twojej instalacji**, nie kopiowany z repo: katalog repo,
`ruby` z Twojego PATH-u (`.rbenv`/`asdf`), port i login z zalogowanego `gh`. Wymusza
też `SOLID_QUEUE_IN_PUMA=1` — launchd startuje `bin/rails server` wprost, więc bez tego
apka wstałaby bez workerów i żadne review nigdy nie ruszyłoby (patrz „Problemy").
Logi: `log/autostart.out.log` i `log/autostart.err.log`.

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
