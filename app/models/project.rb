require "shellwords"

class Project < ApplicationRecord
  # Adres repo na GitHubie — z niego bierzemy slug „owner/repo" do sprawdzenia,
  # czy wklejony PR należy do tego projektu. `.git` i ukośnik na końcu wpadają
  # przy kopiowaniu z GitHuba, więc regexp je zjada, zamiast odrzucać adres.
  GITHUB_REPO_URL = %r{\Ahttps?://(?:www\.)?github\.com/(?<owner>[\w.-]+)/(?<repo>[\w.-]+?)(?:\.git)?/?\z}

  has_many :reviews, dependent: :destroy
  has_many :inbox_items, dependent: :destroy
  has_many :directory_entries, dependent: :destroy

  # Token API trackera (Intum/Sugester) — w bazie zaszyfrowany; formularz pokazuje
  # tylko placeholder „ustawiony", nigdy wartość.
  encrypts :intum_api_token

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  # Jedyny porządek list projektów (grid, archiwum, fallback main) — wspólny scope,
  # żeby „domyślny główny = pierwsza karta gridu" było strukturalne, nie umowne.
  scope :by_name, -> { order(:name) }
  # Bez adresu repo nie ma czego pytać GitHuba o kolejkę „czeka na Twoje review".
  scope :with_repo, -> { where.not(repo_url: [ nil, "" ]) }

  validates :name, :repo_path, :worktree_command, presence: true
  # Nazwa identyfikuje projekt na liście i w nagłówkach — duplikatów nie dałoby
  # się odróżnić.
  validates :name, uniqueness: true
  # Config trafia do CLAUDE_CONFIG_DIR spawnowanego procesu, więc — tak samo jak
  # przy przełączaniu konta w Review — przyjmujemy wyłącznie ścieżki z listy.
  # Bez allow_blank: `inclusion` samo odrzuca puste pole (nil/"" nie ma na liście),
  # więc osobne `presence` dawało dwa komunikaty na to samo puste pole.
  validates :default_claude_config, inclusion: { in: Review::CLAUDE_CONFIGS.map(&:last),
                                                 message: "nie jest jednym z dostępnych configów" }
  validates :default_model, inclusion: { in: Review::MODELS }, allow_blank: true
  validates :default_effort, inclusion: { in: Review::EFFORTS }, allow_blank: true
  validates :repo_url, format: { with: GITHUB_REPO_URL, message: "musi być adresem repozytorium na GitHubie" },
                       allow_blank: true
  # Komendy trafiają do `format(cmd, branch: ...)` w WorktreeManager. Zła literówka
  # w kluczu (%{brnach}) albo goły procent (KeyError/TypeError) nie są łapane przez
  # WorktreeManager::Error — bez tej walidacji ujawniają się dopiero przy próbie
  # usunięcia review, już po skasowaniu jego artefaktów (remove_artifacts idzie przed
  # remove_worktree w before_destroy).
  validate :worktree_commands_are_formattable
  # Komenda skopiowana z innego projektu (bin/worktree-docker vs bin/worktree)
  # wybuchała dopiero przy pierwszym review — jako failed z "no such file or
  # directory". Sprawdzamy istnienie skryptu już przy zapisie projektu.
  # Warunek `if`: walidacja czyta dysk, więc odpala się tylko gdy zmieniło się
  # coś, co na nią wpływa — zapis niepowiązanych pól (np. archived_at) nie
  # wywali się na projekcie, któremu ktoś w międzyczasie przeniósł repo.
  validate :worktree_executables_exist, if: :worktree_setup_changed?

  # Strona wejściowa pokazuje kolejki dokładnie JEDNEGO projektu — tego. Wybór
  # (make_main!) to touch main_at i najpóźniejszy wygrywa, więc przełączenie nie
  # musi zerować pozostałych wierszy. Fallback: pierwszy aktywny wg by_name — ten
  # sam porządek co grid projektów, więc „domyślny" jest przewidywalny.
  def self.main
    active.where.not(main_at: nil).order(main_at: :desc).first || active.by_name.first
  end

  def make_main!
    update!(main_at: Time.current)
  end

  def archived?
    archived_at.present?
  end

  # Ten sam tekst pilnuje dwóch miejsc: walidacji na Review (project_not_archived)
  # i guarda na GET .../reviews/new w ReviewsController — jedno źródło zamiast
  # dwóch literalnie identycznych stringów.
  def archived_notice
    "Projekt #{name} jest zarchiwizowany — przywróć go, żeby dodać review"
  end

  # Kolejka z GitHuba jest odświeżana w tle, więc strona wejściowa pokazuje ostatni
  # znany stan i zleca odświeżenie tylko, gdy zdążył się zestarzeć.
  def inbox_stale?
    inbox_checked_at.nil? || inbox_checked_at < (GithubInbox::STALE_AFTER - GithubInbox::TICK_GRACE).ago
  end

  def github_slug
    match = GITHUB_REPO_URL.match(repo_url.to_s)
    "#{match[:owner]}/#{match[:repo]}" if match
  end

  # Host API trackera wycinany z prefiksu zadań (np. https://tracker.example.com/organize/tasks/
  # → https://tracker.example.com) — osobne pole byłoby drugim miejscem na tę samą prawdę.
  def intum_base_url
    uri = URI.parse(task_url_prefix.to_s)
    "#{uri.scheme}://#{uri.host}" if uri.scheme && uri.host
  rescue URI::InvalidURIError
    nil
  end

  # Pełna integracja (lista osób, komentarz z responsible przez HTTP) wymaga
  # obu: adresu trackera i tokena. Bez tego dashboard działa jak dotychczas.
  def intum_enabled?
    intum_base_url.present? && intum_api_token.present?
  end

  private

  def worktree_commands_are_formattable
    %i[worktree_command worktree_delete_command].each do |attr|
      next if self[attr].blank?

      format(self[attr], branch: "example-branch")
    rescue ArgumentError, KeyError, TypeError
      errors.add(attr, "ma zły wzorzec — użyj %{branch}, a znak procenta zapisz jako %%")
    end
  end

  def worktree_setup_changed?
    %i[repo_path worktree_command worktree_delete_command]
      .any? { |attr| will_save_change_to_attribute?(attr) }
  end

  def worktree_executables_exist
    return if repo_path.blank?

    unless File.directory?(repo_path)
      errors.add(:repo_path, "nie istnieje na dysku")
      return
    end

    %i[worktree_command worktree_delete_command].each do |attr|
      exe = first_command_token(self[attr])
      next if exe.blank? || executable_exists?(exe)

      errors.add(attr, missing_executable_message(exe))
    end
  end

  # Pierwszy token komendy z pominięciem przypisań env (FOO=1 bin/cmd).
  def first_command_token(command)
    Shellwords.split(command.to_s).find { |token| !token.match?(/\A\w+=/) }
  rescue ArgumentError
    nil
  end

  # WorktreeManager odpala komendę z chdir: repo_path, więc ścieżki względne
  # rozwiązujemy tak samo; goły program (git, make) szukany jest w PATH
  # subprocesu (CommandRunner), nie w PATH procesu Rails — bywają różne.
  def executable_exists?(exe)
    if exe.include?("/")
      runnable_file?(File.expand_path(exe, repo_path))
    else
      CommandRunner.executable_in_path?(exe)
    end
  end

  def runnable_file?(path)
    File.file?(path) && File.executable?(path)
  end

  def missing_executable_message(exe)
    return "wskazuje na program #{exe}, którego nie ma w PATH" unless exe.include?("/")

    message = "wskazuje na skrypt #{exe}, którego nie ma w #{repo_path}"
    similar = similar_script(exe)
    message += " — może chodziło o #{similar}?" if similar
    message
  end

  # Podpowiedź dla literówki lub komendy skopiowanej z innego projektu
  # (bin/worktree-docker vs bin/worktree) — słownikiem są wykonywalne pliki
  # z katalogu, w którym miał być brakujący skrypt.
  def similar_script(exe)
    dir = File.expand_path(File.dirname(exe), repo_path)
    scripts = Dir.glob("*", base: dir).select { |f| runnable_file?(File.join(dir, f)) }
    match = DidYouMean::SpellChecker.new(dictionary: scripts).correct(File.basename(exe)).first
    File.join(File.dirname(exe), match) if match
  end
end
