class Review < ApplicationRecord
  STATUSES = %w[created describing ready reviewing reviewed decided waiting_review merged closed failed].freeze
  # Cykl życia opisu zadania — niezależny od statusu review: opis zadania nie
  # blokuje `ready`, a jego porażka nie kładzie całego review.
  TASK_DESCRIPTION_STATUSES = %w[skipped queued running ready failed].freeze
  # Komentarz do zadania po decyzji — dosłownie ten sam kształt cyklu co opis
  # zadania (stąd alias, nie kopia): porażka nie dotyka decyzji na GitHubie.
  TASK_COMMENT_STATUSES = TASK_DESCRIPTION_STATUSES
  # Stany końcowe: PR zniknął z GitHuba (wjechał albo autor go porzucił), więc nie ma
  # już czego review'ować ani o co pytać. Wypadają ze due_for_github_check.
  FINISHED_STATUSES = %w[merged closed].freeze
  # Statusy, w których warto jeszcze pytać GitHuba o stan PR-a. „waiting_review" jest
  # tu, bo inaczej review, którego PR wjechał po prośbie o poprawki, wisiałby
  # w „czeka ponowne review" do końca świata.
  CHECKABLE_STATUSES = %w[decided waiting_review].freeze
  # Statusy, z których wolno odpalić followup. `decided` jest tu dla review, których
  # GitHub nigdy nie przestawi w waiting_review: własnego PR-a nie da się zgłosić
  # samemu sobie do review, a na obcym branchu autor po prostu nie musi klikać
  # re-requestu — a zmiany i tak trzeba sprawdzić.
  FOLLOWUPABLE_STATUSES = %w[reviewed waiting_review decided].freeze
  # Kubełki liczników na liście projektów. „Czeka na Ciebie" to wszystko, co stoi
  # i czeka na kliknięcie — łącznie z `failed`, bo tam też decyzja należy do człowieka.
  ATTENTION_STATUSES = %w[ready reviewed waiting_review failed].freeze
  # Kolejność sekcji „Rozpoczęte w dashboardzie" na stronie wejściowej. Najpierw to,
  # co jest zepsute albo blokuje kogoś innego (padnięta sesja, gotowe znaleziska,
  # autor czekający na ponowne review), na końcu review jeszcze nieodpalone.
  ATTENTION_ORDER = %w[failed reviewed waiting_review ready].freeze
  # „created" jest tu, bo review siedzi w tym statusie od stworzenia aż do startu
  # DescribeReviewJob — a między zakolejkowaniem a workerem potrafi minąć kilkanaście
  # minut (patrz komentarze w ReviewsController). Bez tego świeżo założone review
  # znika z obu kubełków i jest widoczne tylko w „Wszystkich".
  IN_PROGRESS_STATUSES = %w[created describing reviewing].freeze
  DECISIONS = %w[approve reject comment].freeze
  # Obszary review — odpowiadają sekcjom /rev; klucz → etykieta w widoku.
  AREAS = {
    "functionality" => "Funkcjonalność",
    "ux" => "UX",
    "readability" => "Czytelność",
    "api" => "API",
    "project_rules" => "Zasady projektu",
    "qa_playwright" => "QA + Playwright"
  }.freeze
  # Dostępne configi Claude CLI na tej maszynie — wybierane per-review, nie per-projekt.
  # Lista jest per-maszyna, więc żyje w gitignorowanym config/claude_configs.yml
  # (wzór: config/claude_configs.example.yml), nie w kodzie. W testach zawsze
  # wartości stałe: wynik testu nie może zależeć od pliku na maszynie dewelopera.
  CLAUDE_CONFIGS_PATH = Rails.root.join("config", "claude_configs.yml")
  CLAUDE_CONFIGS =
    if Rails.env.test?
      [ [ "config A (~/.claude)", "/Users/dev/.claude" ],
        [ "config B (~/.claude-b)", "/Users/dev/.claude-b" ] ]
    elsif File.exist?(CLAUDE_CONFIGS_PATH)
      YAML.safe_load_file(CLAUDE_CONFIGS_PATH).map { |label, path| [ label, path ] }
    else
      [ [ "claude (~/.claude)", File.join(Dir.home, ".claude") ] ]
    end.freeze
  # Aliasy modeli claude CLI; pusty = domyślny model z wybranego configu.
  MODELS = %w[fable opus sonnet haiku].freeze
  EFFORTS = %w[low medium high xhigh max].freeze
  # Jak często wolno spytać GitHuba o re-request per review (cache w github_checked_at).
  GITHUB_CHECK_INTERVAL = 1.hour
  # Sesje, do których się wraca przez `--resume`. `describe` jest osobną, krótką
  # sesją, której nikt nigdy nie wznawia — jej kontekst nie mówi nic o tym, czy
  # zmieści się kolejny followup.
  RESUMABLE_KINDS = %w[review followup compact].freeze

  # Odczyt zapełnienia okna. Trzy stany, nie dwa: brak sesji (nil z context_usage),
  # sesja bez pomiaru (measured? == false) i pomiar — widok mówi w każdym co innego.
  ContextUsage = Struct.new(:tokens, :window) do
    def measured? = tokens.present?

    def percent = tokens && window ? (tokens * 100.0 / window).round : nil
  end

  # Config trafia do CLAUDE_CONFIG_DIR spawnowanego procesu, więc przyjmujemy
  # wyłącznie wartości z listy — nigdy dowolnej ścieżki z formularza.
  def self.claude_config?(path)
    CLAUDE_CONFIGS.any? { |(_label, value)| value == path }
  end

  def self.claude_config_label(path)
    CLAUDE_CONFIGS.find { |(_label, value)| value == path }&.first || path
  end

  belongs_to :project
  has_many :claude_runs, dependent: :destroy
  has_many :findings, dependent: :destroy
  has_many :playwright_runs, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :task_description_status, inclusion: { in: TASK_DESCRIPTION_STATUSES }
  validates :task_comment_status, inclusion: { in: TASK_COMMENT_STATUSES }
  validates :decision, inclusion: { in: DECISIONS }, allow_nil: true
  # Branch trafia do komend shellowych (bin/worktree-docker) — przepuszczamy
  # tylko znaki legalne w nazwach gitowych branchy.
  validates :branch, format: { with: %r{\A[\w./-]+\z}, message: "zawiera niedozwolone znaki" }, allow_blank: true
  validates :model, inclusion: { in: MODELS }, allow_blank: true
  validates :effort, inclusion: { in: EFFORTS }, allow_blank: true
  # Ta sama wartość jest już utwardzona po stronie Project (default_claude_config);
  # zostawienie tej otwartą byłoby niespójne, bo trafia do CLAUDE_CONFIG_DIR
  # spawnowanego procesu tak samo jak default_claude_config.
  # if: claude_config_changed? — walidujemy tylko wtedy, gdy KTOŚ jawnie ustawia tę
  # wartość (formularz create, switch_config), a nie każdy update!. Bez tego
  # warunku fail! (awaryjna ścieżka bez rescue, patrz komentarz przy niej) rzucałby
  # RecordInvalid za każdym razem, gdy review ma dowolny claude_config sprzed tej
  # walidacji — dokładnie ten sam problem, który project_not_archived/
  # pr_url_matches_project_repo rozwiązują przez on: :create, tylko że tu pole
  # bywa też legalnie zmieniane po stworzeniu (switch_config).
  validates :claude_config, inclusion: { in: CLAUDE_CONFIGS.map(&:last) }, allow_blank: true,
                           if: :claude_config_changed?

  validate :pr_or_task_present
  # Tylko przy tworzeniu: pilnujemy momentu wklejenia linku, a nie trwałej
  # niezmienności relacji. Repo projektu może się zmienić później (formularz
  # edycji projektu) — wtedy walidacja nie może zamrozić istniejących review,
  # bo joby aktualizują je przez update!, a fail! jest awaryjną ścieżką
  # raportowania błędów (bez rescue) używaną też przez OrphanedRunsCleanup.
  validate :pr_url_matches_project_repo, on: :create
  # Drugi review tego samego PR-a to niemal zawsze pomyłka — podwójna praca i drugi
  # komplet komentarzy na PR. Zamiast tworzyć duplikat, kontroler linkuje w błędzie
  # do istniejącego review (stąd duplicate_review niżej). Porównanie po kluczu
  # z GithubClient.pr_key, nie po surowym stringu — patrz komentarz tam.
  # on: :create jak wyżej. To zapora przed pomyłką w formularzu, nie twardy
  # niezmiennik: bez znormalizowanej kolumny nie ma na czym postawić unikalnego
  # indeksu, więc dwa submity w wyścigu teoretycznie przejdą oba.
  validate :pr_url_not_duplicated, on: :create
  # To samo dotyczy archiwizacji projektu — ma zamknąć drogę do NOWYCH review,
  # a nie zamrozić istniejące — te wciąż aktualizują status z jobów.
  validate :project_not_archived, on: :create

  # Ustawiane przez pr_url_not_duplicated — kontroler buduje z tego link
  # w komunikacie błędu.
  attr_reader :duplicate_review

  # Co w ogóle warto pytać GitHuba — bez względu na cache. Osobno od
  # due_for_github_check, bo ręczne „Sprawdź teraz" potrzebuje tego warunku
  # z pominięciem stempla czasu.
  scope :checkable, -> { where(status: CHECKABLE_STATUSES).where.not(pr_url: [ nil, "" ]) }
  scope :due_for_github_check, -> {
    checkable.where("github_checked_at IS NULL OR github_checked_at < ?", GITHUB_CHECK_INTERVAL.ago)
  }
  # Review powiązane z czymś na zewnątrz (PR albo zadanie) — w odróżnieniu od
  # samoreview, które jest prywatną rundą przed wystawieniem PR-a i nie wchodzi
  # do kolejek ani liczników „czeka na Ciebie" na stronie wejściowej.
  scope :outward, -> {
    where("(pr_url IS NOT NULL AND pr_url <> '') OR (task_url IS NOT NULL AND task_url <> '')")
  }

  # prepend: true — callbacki dependent: :destroy z has_many wyżej kasują
  # claude_runs wcześniej; bez prependa nie byłoby już czego ubijać.
  before_destroy :halt_running_processes, prepend: true
  before_destroy :remove_artifacts, :remove_worktree

  # Ustawiane przez remove_worktree — kontroler pokazuje to userowi po destroy,
  # bo nieudane sprzątanie nie przerywa usuwania rekordu.
  attr_reader :worktree_removal_error

  # Live update panelu na show i wiersza listy — joby zmieniają status, przeglądarka widzi od razu.
  after_update_commit :broadcast_panel!, :broadcast_row!

  def artifacts_dir
    Rails.root.join("storage", "reviews", id.to_s)
  end

  # Bez PR-a nie ma czego approve'ować na GitHubie — wynik zostaje w dashboardzie.
  def github_actions_available?
    pr_url.present?
  end

  # Link identyfikujący zadanie — PR, a gdy go nie ma, link do zadania.
  # Samoreview nie ma żadnego z nich, więc identyfikuje je branch.
  def task_link
    pr_url.presence || task_url.presence || (branch.present? ? "branch #{branch}" : nil)
  end

  # Prywatna runda review własnego brancha, zanim powstanie PR — celowo bez
  # kolumny: brak obu linków JEST definicją samoreview (walidacja wymusza branch).
  def self_review?
    pr_url.blank? && task_url.blank?
  end

  # Weryfikacja poprawek ma sens tylko po wysłanej decyzji i tylko gdy wiemy, na jaki
  # stan kodu patrzyliśmy. Bez znalezisk nie ma czego sprawdzać, bez brancha nie ma
  # czego porównać (review z samego zadania).
  def fixes_verifiable?
    status.in?(%w[decided waiting_review]) && pr_url.present? && branch.present? &&
      decision_head_sha.present? && findings.any?
  end

  # Rozkład werdyktów do nagłówka sekcji; pusty hash, gdy nic jeszcze nie sprawdzono.
  def fix_summary
    findings.filter_map(&:fix_status).tally
  end

  # Weryfikacja zasadności znalezisk świeżą sesją. Branch jest konieczny — sesja
  # musi przeczytać kod, a review z samego zadania nie ma czego czytać. Statusy jak
  # przy followupie: przed decyzją weryfikacja jest najcenniejsza, ale po decyzji
  # też bywa potrzebna (autor podważa uwagi). Guard na run w locie: druga sesja
  # pisałaby po tych samych werdyktach.
  def findings_verifiable?
    status.in?(FOLLOWUPABLE_STATUSES) && branch.present? && findings.any? &&
      !findings_verification_in_progress?
  end

  # Weryfikacja chodzi cyklem pobocznym i nie zmienia statusu review — bez tego
  # pytania ani lista, ani karta znalezisk nie miałyby jak pokazać, że coś trwa.
  def findings_verification_in_progress?
    claude_runs.exists?(kind: "verify_findings", status: %w[pending running])
  end

  def verdict_summary
    findings.filter_map(&:verdict).tally
  end

  def finished?
    FINISHED_STATUSES.include?(status)
  end

  def effective_claude_config
    claude_config.presence || project.default_claude_config
  end

  # Czy od ostatniej udanej sesji zmieniło się konto Claude. Wtedy transkrypt może
  # nie przenieść się w całości, więc prompt musi dowieźć kontekst sam.
  def switched_account?
    last_succeeded = claude_runs.where(status: "succeeded").order(:id).last
    last_succeeded.present? && last_succeeded.claude_config != effective_claude_config
  end

  def selected_areas
    Array(scope&.dig("areas"))
  end

  # Domyślnie włączone: review sprzed tej zmiany nie ma klucza w scope, a checkbox
  # ma być zaznaczony, dopóki user go świadomie nie odklika.
  def inline_comments?
    scope&.dig("inline_comments") != false
  end

  # Ścieżka do dokumentacji projektu — ale tylko gdy katalog realnie leży w repo.
  # Prompt nie może kazać czytać czegoś, czego nie ma: sesja zmarnowałaby turę na
  # `ls` nieistniejącego katalogu i zaczęła zgadywać, gdzie te reguły trzymamy.
  def available_docs_path
    path = project.docs_path.presence
    path if path && Dir.exist?(File.join(workdir, path))
  end

  def scope_notes
    scope&.dig("notes").to_s
  end

  # Renderuje panel Review — używane też jawnie tam, gdzie zmiana nie dotyczy
  # samego Review (np. po zakończeniu PlaywrightRun) i nie odpali callbacku wyżej.
  def broadcast_panel!
    broadcast_safely("broadcast_panel!") do
      broadcast_replace_to self, target: "review_#{id}_panel", partial: "reviews/panel", locals: { review: self }
    end
  end

  # Wiersz listy — wykrycie waiting_review dzieje się w tle po wejściu na listę,
  # więc bez broadcastu byłoby niewidoczne w sesji, która je uruchomiła.
  # Strumień jest per projekt: globalny wpychałby wiersz z projektu A na otwartą
  # listę projektu B, gdzie ten wiersz w ogóle nie istnieje.
  # running_ids liczone tylko dla tego wiersza (exists? po indeksie review_id),
  # nie skanem całej tabeli jak w kontrolerze listy.
  def broadcast_row!
    return unless saved_change_to_status?

    broadcast_safely("broadcast_row!") do
      broadcast_replace_to project, :reviews, target: "review_row_#{id}", partial: "reviews/review_row",
                           locals: { review: self, running_ids: claude_runs.where(status: "running").exists? ? [ id ] : [],
                                     verifying_ids: findings_verification_in_progress? ? [ id ] : [] }
    end
  end

  def fail!(message)
    update!(status: "failed", error_message: message)
  end

  def last_claude_run
    claude_runs.order(:id).last
  end

  # Ostatni krok CYKLU review — do ponowienia po awarii (switch_config). Runy
  # poboczne (compact, describe_task) nie są krokami cyklu: gdyby decydowały,
  # ponowienie po padniętym review odpaliłoby describe od zera.
  def last_lifecycle_run
    claude_runs.where(kind: ClaudeRun::LIFECYCLE_KINDS).order(:id).last
  end

  # Powód ostatniej porażki cyklu pobocznego — z runa, nie z kolumny treści:
  # nieudane odświeżenie nie może zamazać dobrej treści komunikatem błędu.
  def task_description_error
    side_run_error("describe_task")
  end

  def task_comment_error
    side_run_error("comment_task")
  end

  # Instrukcja dla sesji komentującej: zamrożona przy decyzji wygrywa (Ponów używa
  # tej samej), default projektu tylko zanim user cokolwiek zdecydował.
  def effective_task_comment_instructions
    task_comment_instructions.presence || project.task_comment_instructions
  end

  # Sesja, którą wznowi followup — i ta sama, którą ma sens kompaktować. Świadomie
  # sprawdzana na dysku (session_available_in?): po przełączeniu konta plik sesji
  # bywa w drugim configu, a `--resume` zwróciłby wtedy „No conversation found".
  def resumable_session_run(config = effective_claude_config)
    claude_runs.where(kind: RESUMABLE_KINDS, status: "succeeded")
               .where.not(session_id: nil).order(id: :desc)
               .find { |run| run.session_available_in?(config) }
  end

  # Sesje liczone do kontekstu — najstarsza pierwsza, bo karta pokazuje je jako
  # historię narastania.
  def context_runs
    claude_runs.where(kind: RESUMABLE_KINDS).order(:id)
  end

  # Wynik ostatniej kompakcji. Nieudany compact nie wrzuca review w „failed",
  # więc to jedyne miejsce, w którym widać, że się nie powiodła.
  def last_compact_run
    claude_runs.where(kind: "compact").order(:id).last
  end

  # Zapełnienie okna sesji, do której wracają followupy. Bierzemy najnowszy run
  # i już — świadomie bez schodzenia niżej: po compakcie poprzedni pomiar jest
  # nieprawdą, a nowy powstanie dopiero przy następnej sesji.
  def context_usage
    run = context_runs.last
    return if run.nil?

    ContextUsage.new(run.context_tokens, run.context_window || last_known_context_window)
  end

  # Kompaktować da się tylko sesję, która istnieje na bieżącym koncie i w której nic
  # nie pracuje — dwie kompakcje naraz to wyścig o ten sam plik sesji. Sam brak
  # działającego runu nie wystarcza: między kliknięciem a startem workera run
  # jeszcze nie istnieje, więc drugi klik przechodziłby przez tę bramkę.
  # Skończone review nie dostanie już followupu, więc nie ma czego ratować.
  def compactable?
    !finished? && !IN_PROGRESS_STATUSES.include?(status) &&
      running_claude_run.nil? && resumable_session_run.present?
  end

  # Sesja, którą pokazuje panel postępu. Świadomie tylko „running": zakończony run
  # ma nieaktualny last_message, a wyświetlony w trakcie oczekiwania na workera
  # udawałby bieżący postęp. Brak wyniku = zadanie czeka w kolejce.
  def running_claude_run
    claude_runs.where(status: "running").order(:id).last
  end

  # Wszystkie sesje, do których da się wrócić — najnowsza pierwsza. Świadomie nie
  # jedna: po nieudanym ponowieniu ostatnia sesja bywa tą, która padła po kilku
  # sekundach, a cała praca została w poprzedniej.
  def resumable_claude_runs
    claude_runs.where.not(session_id: nil).order(id: :desc)
  end

  # Sesja mogła zapisać wynik na dysku, zanim job zdążył go zaimportować
  # (np. restart apki w trakcie) — wtedy da się go odzyskać bez ponownego review.
  def result_on_disk?
    File.exist?(artifacts_dir.join("result.json"))
  end

  def workdir
    worktree_path.presence || project.repo_path
  end

  # Katalog worktree tego review — nil, gdy review pracuje wprost w repo projektu.
  def own_worktree_path
    return if worktree_path.blank? || worktree_path == project.repo_path

    worktree_path
  end

  # Czy ten katalog jeszcze stoi. `worktree_path` bywa nieaktualny: dashboard zeruje go
  # tylko przy usuwaniu z panelu, a worktree ginie też poza nim (`bin/worktree-docker -d`
  # z terminala, sprzątanie dysku) — i wtedy w bazie zostaje ścieżka donikąd, po której
  # nie widać, że followup wystartuje w nieistniejącym katalogu.
  def worktree_exists?
    own_worktree_path.present? && Dir.exist?(own_worktree_path)
  end

  # Własne worktree review — katalog inny niż główne repo projektu, który da się usunąć
  # komendą projektu. Warunek na worktree_delete_command jest twardy: bez niego
  # format(nil, branch:) sypie NoMethodError zamiast czytelnego błędu.
  def own_worktree?
    branch.present? && own_worktree_path.present? && project.worktree_delete_command.present?
  end

  # Przycisk „Usuń worktree" — tylko gdy nic już w nim nie pracuje.
  def worktree_removable?
    own_worktree? && (finished? || %w[reviewed decided failed].include?(status))
  end

  private

  def side_run_error(kind)
    claude_runs.where(kind: kind).order(:id).last&.error_message
  end

  # Broadcast to kosmetyka (odświeżenie strony pokaże stan) — jego błąd nie może
  # wywracać logiki biznesowej ani boota (np. render przed załadowaniem routes).
  def broadcast_safely(label)
    yield
  rescue StandardError => e
    Rails.logger.warn("#{label} dla review #{id} nie powiódł się: #{e.class}: #{e.message}")
  end

  # Rozmiar okna przychodzi dopiero z eventem `result`, więc bieżąca sesja poznaje
  # go na końcu. Model review jest stały przez całe jego życie, więc okno
  # z poprzedniej sesji jest tym samym oknem.
  def last_known_context_window
    claude_runs.where.not(context_window: nil).order(:id).last&.context_window
  end

  # Sam branch wystarcza: samoreview własnych zmian przed wystawieniem PR-a.
  def pr_or_task_present
    return if pr_url.present? || task_url.present? || branch.present?

    errors.add(:base, "Podaj link do PR, link do zadania albo branch (samoreview)")
  end

  # Wklejenie PR-a z innego projektu kończyłoby się `gh pr checkout` i worktree
  # w cudzym repo — cicho i kosztownie. Sprawdzamy tylko, gdy projekt zna swoje
  # repo; bez `repo_url` (praca po linkach do zadań) walidacja milczy.
  def pr_url_matches_project_repo
    return if pr_url.blank?

    expected = project&.github_slug
    return if expected.blank?

    match = GithubClient.parse_pr_url(pr_url)
    return errors.add(:pr_url, "nie wygląda na link do PR-a na GitHubie") if match.nil?

    actual = "#{match[:owner]}/#{match[:repo]}"
    return if actual.casecmp?(expected)

    errors.add(:pr_url, "należy do #{actual}, a projekt #{project.name} wskazuje na #{expected}")
  end

  # errors[:pr_url].any? — pr_url_matches_project_repo już odrzucił ten link, więc
  # skan po review projektu byłby pracą na submit, który i tak nie przejdzie.
  # select(:id, :pr_url) — porównujemy jeden krótki string, a pełne wiersze
  # ciągnęłyby z bazy raw_result i resztę długich kolumn tekstowych; id wystarcza
  # kontrolerowi do zbudowania linku.
  def pr_url_not_duplicated
    return if pr_url.blank? || project.nil? || errors[:pr_url].any?

    key = pr_canonical(pr_url)
    @duplicate_review = project.reviews.select(:id, :pr_url).find { |other| pr_canonical(other.pr_url) == key }
    errors.add(:pr_url, "ma już review w tym projekcie") if @duplicate_review
  end

  # Linki spoza wzorca GitHubowego (projekt bez repo_url może trzymać PR-y skądinąd)
  # porównujemy dosłownie; review bez pr_url daje "" i nigdy nie dorówna kluczowi.
  def pr_canonical(url)
    GithubClient.pr_key(url) || url.to_s
  end

  def project_not_archived
    return unless project&.archived?

    errors.add(:base, project.archived_notice)
  end

  def halt_running_processes
    claude_runs.where(status: "running").where.not(pid: nil).each do |run|
      CommandRunner.kill_group(run.pid)
    end
  end

  def remove_artifacts
    FileUtils.rm_rf(artifacts_dir)
  end

  # Worktree ginie razem z review — inaczej po usunięciu rekordu zostaje katalog
  # z bazą, o którym nic już w dashboardzie nie przypomina. Komenda projektu (nie
  # `git worktree remove`) — ona jedna kasuje też bazy i sam katalog.
  # Błąd nie przerywa destroy: zepsuty docker nie może uwięzić review w dashboardzie.
  # StandardError, nie tylko WorktreeManager::Error — zły wzorzec komendy (literówka
  # w %{branch}, goły %) rzuca KeyError/TypeError z samego `format`, zanim WorktreeManager
  # zdąży cokolwiek odpalić i opakować to w swój Error. remove_artifacts już się
  # wykonał (kolejność before_destroy), więc wąski rescue zostawiałby review zawieszone
  # w dashboardzie z artefaktami bezpowrotnie skasowanymi.
  def remove_worktree
    return unless own_worktree?

    WorktreeManager.new(project).remove(branch)
  rescue StandardError => e
    Rails.logger.warn("Usuwanie worktree #{branch} przy destroy review #{id}: #{e.message}")
    @worktree_removal_error = e.message
  end
end
