class ClaudeRun < ApplicationRecord
  KINDS = %w[describe describe_task review followup compact comment_task].freeze
  # Kroki cyklu review (describe → review → followup) — w odróżnieniu od runów
  # pobocznych (compact, describe_task), które mają własne przyciski ponowienia
  # i nie mogą decydować o wznawianiu cyklu po awarii.
  LIFECYCLE_KINDS = %w[describe review followup].freeze
  STATUSES = %w[pending running succeeded failed aborted].freeze
  # Review z QA w Playwright potrafi zająć ponad pół godziny (analiza + pisanie
  # i debugowanie testu), a wynik powstaje dopiero na końcu — ucięcie w połowie
  # kasuje całą pracę. Zmierzone 27 lipca 2026: review 9 = 32 min, review 11 = 27 min,
  # więc 1800 s ucinałoby zdrowe sesje. Zwisy łapie wcześniej watchdog ciszy.
  # Kompakcja to jedno wywołanie modelu na podsumowanie historii — jeśli nie zmieści
  # się w 10 minutach, to nie zmieści się wcale. describe_task dostaje tyle co
  # describe: czytanie zadania z komentarzami to podobny profil (kilka tur narzędzi,
  # zero pisania kodu) — do zweryfikowania pomiarem, gdy będą dane.
  # comment_task: otwarcie zadania + napisanie i dodanie jednego komentarza — profil
  # jak describe_task (kilka tur narzędzi, zero kodu), więc ten sam limit.
  TIMEOUTS = { "describe" => 900, "describe_task" => 900, "review" => 3600, "followup" => 1800, "compact" => 600,
               "comment_task" => 900 }.freeze
  # Zwis sesji objawia się ciszą w strumieniu — claude przestaje emitować zdarzenia,
  # choć proces żyje. Czekanie do limitu całkowitego nic wtedy nie daje, więc ubijamy
  # wcześniej i (dla review) ponawiamy. Pracująca sesja bije zdarzeniami co kilka sekund,
  # nawet gdy czeka na własne narzędzie, więc 15 minut ciszy to na pewno awaria.
  IDLE_TIMEOUT = 900

  belongs_to :review

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :claude_config, presence: true

  attribute :status, :string, default: "pending"

  after_update_commit -> {
    broadcast_replace_to review, target: "review_#{review_id}_progress",
                         partial: "reviews/progress", locals: { review: review.reload }
  }, if: -> { saved_change_to_last_message? || saved_change_to_status? || saved_change_to_started_at? }

  # Licznik kontekstu ma rosnąć w trakcie sesji, a nie dopiero po odświeżeniu —
  # to jedyna liczba w panelu, która mówi, czy następny followup się jeszcze zmieści.
  after_update_commit -> {
    broadcast_replace_to review, target: "review_#{review_id}_context",
                         partial: "reviews/context", locals: { review: review.reload }
  }, if: -> { saved_change_to_context_tokens? || saved_change_to_context_window? || saved_change_to_status? }

  def log_path
    review.artifacts_dir.join("#{kind}.log")
  end

  def timeout_seconds
    TIMEOUTS.fetch(kind)
  end

  # Nie ma sensu pilnować ciszy dłużej, niż trwa cały limit — inaczej dla krótkich
  # sesji (describe) watchdog nigdy by nie zadziałał.
  def idle_timeout_seconds
    [ IDLE_TIMEOUT, timeout_seconds ].min
  end

  # cd jest obowiązkowe: claude trzyma sesje per katalog projektu — resume
  # z innego cwd kończy się "No conversation found".
  def resume_command
    return if session_id.blank?

    "cd #{review.workdir} && CLAUDE_CONFIG_DIR=#{claude_config} claude --resume #{session_id}"
  end

  # Claude CLI trzyma sesje pod <CLAUDE_CONFIG_DIR>/projects/<slug>/<session_id>.jsonl,
  # gdzie slug to ścieżka robocza z każdym znakiem spoza [A-Za-z0-9] zamienionym na "-".
  def self.path_slug(path)
    path.to_s.gsub(/[^A-Za-z0-9]/, "-")
  end

  def session_file(config = claude_config)
    return if session_id.blank?

    Pathname(config.to_s).join("projects", self.class.path_slug(review.workdir), "#{session_id}.jsonl")
  end

  # Jedyne źródło prawdy o tym, czy `--resume` na danym koncie ma sens. Świadomie
  # z dysku, nie z bazy: sesję da się skopiować albo skasować poza dashboardem,
  # a kolumna zapamiętałaby wtedy nieprawdę.
  def session_available_in?(config)
    file = session_file(config)
    file.present? && file.exist?
  end
end
