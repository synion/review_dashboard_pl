class ReviewsController < ApplicationController
  SORTS = %w[created_at updated_at status decision].freeze
  # Status, w który wraca review, gdy po przełączeniu konta ponawiamy krok,
  # który padł. Klucz to `kind` ostatniego runa; brak runa = ponawiamy describe.
  REQUEUE_STATUSES = { "review" => "reviewing", "followup" => "reviewing", "describe" => "describing" }.freeze

  before_action :set_review, only: %i[show destroy start abort retry_run refresh_task_description remove_worktree reimport switch_config compact]
  before_action :set_project, only: %i[index new create recheck_github]

  def index
    # includes(:project) — wiersz pyta o `own_worktree?`, czyli o komendę usuwania
    # z projektu; bez tego lista robi zapytanie na każdy wiersz.
    @reviews = @project.reviews.includes(:project)
    @reviews = @reviews.where(status: params[:status]) if params[:status].present?
    # @sort/@direction, nie zmienne lokalne: nagłówki tabeli muszą wiedzieć, po czym
    # naprawdę sortujemy, żeby przełączać kierunek tylko na aktywnej kolumnie.
    # Powtórzenie tego wyliczenia w helperze rozjeżdżałoby się przy sort=bzdura.
    @sort = SORTS.include?(params[:sort]) ? params[:sort] : "created_at"
    @direction = params[:direction] == "asc" ? :asc : :desc
    @reviews = @reviews.order(@sort => @direction)
    # Jednym zapytaniem, nie raz na wiersz: „reviewing" bez pracującej sesji znaczy,
    # że job czeka na wolny wątek workera — i to musi być widać już na liście.
    @running_review_ids = ClaudeRun.where(status: "running").distinct.pluck(:review_id)
    enqueue_github_checks(@project.reviews.due_for_github_check)
  end

  # Godzinny cache w github_checked_at znaczy, że re-request zgłoszony tuż po ostatnim
  # sprawdzeniu jest niewidoczny do końca tego okna, a odświeżanie listy nic nie daje.
  # Ten przycisk pomija cache — automat z index zostaje nietknięty.
  def recheck_github
    count = enqueue_github_checks(@project.reviews.checkable)
    # redirect_back, nie project_reviews_path: user stoi zwykle na przefiltrowanej albo
    # posortowanej liście i kliknięcie nie ma go z niej wyrzucać.
    redirect_back fallback_location: project_reviews_path(@project),
                  notice: count.zero? ? "Nie ma review czekających na sygnał z GitHuba" : "Sprawdzam #{count} review na GitHubie…"
  end

  def show
  end

  def new
    # Bez tego guarda GET renderował pełny formularz, który i tak odbije się
    # o project_not_archived dopiero przy submit — przekierowanie od razu jest
    # spójne z resztą kontrolera (patrz start, switch_config).
    if @project.archived?
      return redirect_to project_reviews_path(@project), alert: @project.archived_notice
    end

    @review = @project.reviews.new(claude_config: @project.default_claude_config,
                                   model: @project.default_model,
                                   effort: @project.default_effort)
  end

  def create
    @review = @project.reviews.new(review_params)
    @review.claude_config = @review.effective_claude_config
    # Status przed zapisem, nie update! po nim: rekord jest świeży, a każdy update!
    # na Review to pełny broadcast panelu, którego nikt jeszcze nie ogląda.
    @review.task_description_status = "queued" if params[:fetch_task_description] == "1"
    if @review.save
      DescribeReviewJob.perform_later(@review)
      DescribeTaskJob.perform_later(@review) if @review.task_description_status == "queued"
      redirect_to @review
    else
      flash.now[:error] = create_error_message
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    # Branch i projekt czytamy przed destroy — po nim rekord jest zamrożony, a nazwa
    # brancha jest potrzebna w komunikacie, projekt zaś w adresie powrotu.
    worktree_branch = @review.own_worktree? ? @review.branch : nil
    project = @review.project
    @review.destroy!

    if (error = @review.worktree_removal_error)
      redirect_to project_reviews_path(project), alert: "Review usunięty, ale worktree #{worktree_branch} został — #{error}"
    else
      redirect_to project_reviews_path(project), notice: "Review usunięty razem z artefaktami#{" i worktree #{worktree_branch}" if worktree_branch}"
    end
  end

  def start
    # Guard na podwójny klik / dwie karty: drugi start w locie nadpisałby
    # result.json i findings pierwszego przebiegu.
    return redirect_to(@review, alert: "Review nie jest gotowy do startu (status: #{@review.status})") unless @review.status == "ready"

    # Status przestawiamy tu, nie w jobie: między kolejkowaniem a startem workera
    # potrafi minąć kilkanaście minut i panel nie może wtedy wyglądać jak przed kliknięciem.
    @review.update!(scope: { "areas" => Array(params[:areas]), "notes" => params[:notes].to_s,
                             "inline_comments" => params[:inline_comments] == "1" },
                    status: "reviewing")
    RunReviewJob.perform_later(@review)
    redirect_to @review
  end

  def abort
    run = @review.running_claude_run
    if run&.pid
      CommandRunner.kill_group(run.pid)
      redirect_to @review, notice: "Wysłano sygnał przerwania"
    else
      redirect_to @review, alert: "Nie ma działającego procesu do przerwania"
    end
  end

  def retry_run
    @review.update!(status: @review.description.present? ? "ready" : "created", error_message: nil)
    DescribeReviewJob.perform_later(@review) if @review.status == "created"
    redirect_to @review
  end

  # Odświeżenie łapie nowe komentarze w zadaniu bez przeliczania całego review.
  # Guard na podwójny klik jak w #start: drugi job w locie pisałby po tym samym polu.
  def refresh_task_description
    if %w[queued running].include?(@review.task_description_status)
      return redirect_to(@review, alert: "Opis zadania już się generuje")
    end

    # Status przestawiamy tu, nie w jobie — między kolejkowaniem a startem workera
    # potrafi minąć kilkanaście minut i karta nie może wtedy wyglądać jak przed kliknięciem.
    @review.update!(task_description_status: "queued")
    DescribeTaskJob.perform_later(@review)
    redirect_to @review
  end

  def reimport
    if @review.result_on_disk?
      ReviewResultImporter.call(@review)
    elsif @review.raw_result.present?
      ReviewResultImporter.from_raw_result(@review)
    else
      return redirect_to(review_path(@review), alert: "Brak wyniku na dysku ani w bazie — nie ma czego wczytać")
    end

    @review.update!(status: "reviewed", error_message: nil)
    redirect_to review_path(@review), notice: "Wynik wczytany"
  rescue StandardError => e
    redirect_to review_path(@review), alert: "Nie udało się wczytać wyniku: #{e.message}"
  end

  # Ratunek po wyczerpaniu limitów subskrypcji: review przenosi się na drugie konto
  # razem z plikami sesji, więc dalsza praca ma pełny kontekst.
  def switch_config
    config = params[:claude_config].to_s
    return redirect_to(review_path(@review), alert: "Nieznany config Claude") unless Review.claude_config?(config)
    # Przełączenie na aktywne konto tylko udawałoby ratunek: migracja byłaby pustym
    # przebiegiem, a ponowienie poszłoby na dokładnie to konto, na którym krok padł.
    return redirect_to(review_path(@review), alert: "To już jest aktywne konto") if config == @review.effective_claude_config
    # Kopiowanie pliku sesji pod pracującym procesem to wyścig — najpierw „Przerwij".
    return redirect_to(review_path(@review), alert: "Najpierw przerwij działającą sesję") if @review.running_claude_run

    begin
      copied = SessionMigrator.new(@review).migrate_to(config)
    rescue StandardError => e
      # Wąsko wokół samej migracji: to jedyny krok robiący realne I/O, a alert niżej
      # obiecuje, że config został bez zmian — objęcie nim update! zamieniłoby tę
      # obietnicę w kłamstwo. Błąd tu to zwykle uprawnienia albo brak miejsca na dysku
      # w docelowym configu; ten sam problem uderzyłby w ponowioną sesję, więc nie
      # przełączamy konta na ślepo — user ma naprawić katalog i spróbować znowu.
      return redirect_to(review_path(@review),
                         alert: "Nie udało się przenieść sesji na #{Review.claude_config_label(config)}: #{e.message}. " \
                                "Konto zostaje bez zmian — sprawdź uprawnienia i miejsce na dysku w tym configu i spróbuj ponownie.")
    end

    retrying = @review.status == "failed"
    last = @review.last_lifecycle_run if retrying
    attrs = { claude_config: config }
    # Status przestawiamy tu, nie w jobie: między kolejkowaniem a startem workera
    # potrafi minąć kilkanaście minut, a przez ten czas panel pokazywałby czerwony
    # box „Błąd" z przyciskiem „Ponów" dla kroku, który już czeka w kolejce.
    attrs[:status] = REQUEUE_STATUSES.fetch(last&.kind, "describing") if retrying
    @review.update!(attrs)
    requeue_last_step(last) if retrying

    redirect_to review_path(@review),
                notice: "Przełączono na #{Review.claude_config_label(config)} (przeniesionych sesji: #{copied}). " +
                        (retrying ? "Ponawiam ostatni krok na nowym koncie." : "Kolejne uruchomienie pójdzie na nowe konto.")
  end

  def compact
    unless @review.compactable?
      return redirect_to(review_path(@review),
                         alert: "Nie ma czego kompaktować — sesja pracuje albo nie ma jej na tym koncie")
    end

    # Patrz #start — status musi zmienić się od razu, nie dopiero gdy worker zwolni
    # wątek. Poprzedni status wraca po kompakcji, bo „reviewing" jest tu tylko
    # pożyczone dla panelu postępu i przycisku „Przerwij".
    previous_status = @review.status
    @review.update!(status: "reviewing")
    CompactReviewJob.perform_later(@review, previous_status)
    redirect_to review_path(@review), notice: "Kompaktuję sesję — rozmiar kontekstu zmierzy się przy następnej sesji"
  end

  def remove_worktree
    WorktreeManager.new(@review.project).remove(@review.branch)
    @review.update!(worktree_path: nil)
    redirect_to review_path(@review), notice: "Worktree usunięty"
  # StandardError, nie tylko WorktreeManager::Error — zły wzorzec komendy w formularzu
  # projektu (literówka w %{branch}, goły %) rzuca KeyError/TypeError z `format`,
  # zanim WorktreeManager zdąży to opakować w swój Error. Bez tego user dostawał 500
  # zamiast alertu, tak samo jak przy destroy.
  rescue StandardError => e
    redirect_to review_path(@review), alert: e.message
  end

  private

  # Odpytanie GitHuba o re-request idzie w tle (gh to ~1 s na PR) — render nie czeka
  # na wynik. Stempel github_checked_at kładziemy już przy kolejkowaniu, żeby drugie
  # odświeżenie listy przed startem workera nie zdublowało wywołań gh. Zakres to sam
  # projekt: wejście na jeden dashboard nie ma odpalać `gh` dla wszystkich pozostałych.
  # Relacja przychodzi z zewnątrz, bo dwie ścieżki różnią się tylko nią: index pyta
  # o przeterminowane, recheck_github o wszystkie kwalifikujące się.
  def enqueue_github_checks(reviews)
    due = reviews.to_a
    return 0 if due.empty?

    Review.where(id: due).update_all(github_checked_at: Time.current)
    due.each { |review| CheckReviewRequestJob.perform_later(review) }
    due.size
  end

  def set_project
    @project = Project.find(params[:project_id])
  end

  # Przy duplikacie PR-a doklejamy do błędów link do istniejącego review — sam tekst
  # walidacji nie mówi, gdzie go szukać. safe_join, nie html_safe na sklejce: tekst
  # błędu przechodzi przez escape, bezpieczny zostaje tylko link z link_to.
  def create_error_message
    message = @review.errors.full_messages.to_sentence
    return message unless (existing = @review.duplicate_review)

    helpers.safe_join([ message, helpers.link_to("przejdź do review ##{existing.id}", review_path(existing)) ], " — ")
  end

  # Wznawiamy dokładnie ten krok, który padł — po to jest ten przycisk. Followup
  # dostaje z powrotem swoją uwagę, bo bez niej sesja nie wie, co zweryfikować.
  # Run przychodzi z zewnątrz, bo status wyliczany jest z tego samego `kind` jeszcze
  # przed update! — dwa odczyty rozjechałyby status z zakolejkowanym jobem.
  def requeue_last_step(last)
    case last&.kind
    when "review" then RunReviewJob.perform_later(@review)
    when "followup" then FollowupReviewJob.perform_later(@review, last.user_message.to_s)
    else DescribeReviewJob.perform_later(@review)
    end
  end

  def set_review
    @review = Review.find(params[:id])
  end

  def review_params
    params.require(:review).permit(:pr_url, :task_url, :branch, :claude_config, :model, :effort)
  end
end
