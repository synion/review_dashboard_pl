module ReviewsHelper
  STATUS_LABELS = {
    "created" => "Utworzony", "describing" => "Claude czyta zadanie…", "ready" => "Gotowy do startu",
    "reviewing" => "Review w toku…", "reviewed" => "Review zakończony", "decided" => "Zdecydowany",
    "waiting_review" => "Czeka ponowne review", "merged" => "🎉 Zmergowany", "closed" => "🚫 PR zamknięty",
    "failed" => "Błąd"
  }.freeze

  # Następny ruch, nie stan. Badge odpowiada „w jakim stanie jest review", a strona
  # wejściowa musi odpowiadać „co mam z tym zrobić" — bez tego zdania user tłumaczy
  # sobie status na czynność przy każdym wejściu.
  NEXT_STEPS = {
    "created" => "Czeka na wolnego workera — nic nie klikaj",
    "describing" => "Claude czyta PR i zadanie",
    "ready" => "Zaznacz obszary i odpal review",
    "reviewing" => "Sesja review pracuje",
    "reviewed" => "Przejrzyj znaleziska i wyślij decyzję",
    "waiting_review" => "Autor poprawił — sprawdź zmiany followupem",
    "failed" => "Sesja padła — ponów krok albo przełącz konto"
  }.freeze

  def review_status_label(review) = STATUS_LABELS.fetch(review.status, review.status)

  def review_next_step(review) = NEXT_STEPS[review.status]

  # „czeka 3 dni" zamiast daty: przy wejściu liczy się, czy coś stoi od rana, czy od
  # tygodnia. Formy polskie odmieniamy ręcznie — apka stoi na locale `en`.
  def review_waiting_for(review)
    seconds = (Time.current - review.updated_at).round
    days, hours, minutes = seconds / 86_400, seconds / 3600, seconds / 60
    return "#{days} #{days == 1 ? "dzień" : "dni"}" if days >= 1
    return "#{hours} godz." if hours >= 1
    return "#{minutes} min" if minutes >= 1

    "chwilę"
  end

  # Ten sam format co przy review, ale liczony od sygnału z GitHuba (prośby o review
  # albo cudzego komentarza), a nie od ruchu w dashboardzie.
  def inbox_waiting_for(item)
    return "chwilę" if item.signal_at.blank?

    review_waiting_for(Review.new(updated_at: item.signal_at))
  end

  # Liczba znalezisk z wyróżnieniem blokerów: przy wyborze, co przejrzeć pierwsze,
  # „7 znalezisk · 2 krytyczne" mówi więcej niż sam status „Review zakończony".
  def review_findings_summary(review)
    return nil if review.findings.empty?

    critical = review.findings.count { |finding| finding.priority == "critical" }
    count = review.findings.size
    [ "#{count} #{findings_noun(count)}", critical.positive? ? "#{critical} krytyczne" : nil ].compact.join(" · ")
  end

  # Polska liczba mnoga w trzech formach — apka stoi na locale `en`, więc
  # pluralizacja z i18n dałaby „3 znaleziskos".
  def findings_noun(count)
    return "znalezisko" if count == 1
    return "znaleziska" if (2..4).cover?(count % 10) && !(12..14).cover?(count % 100)

    "znalezisk"
  end

  # Nagłówek sortujący listy review. Kierunek przełącza się tylko na kolumnie, po
  # której już sortujemy — inaczej kliknięcie w „Aktywność" po wcześniejszym
  # przestawieniu „Daty" na rosnąco dziedziczyłoby ten kierunek i lista otwierałaby
  # się od najstarszych. Filtr statusu jedzie z linkiem, bo user zwykle stoi
  # na przefiltrowanej liście i sortowanie nie ma go z niej wyrzucać.
  def review_sort_link(project, label, column)
    direction = @sort == column && @direction != :asc ? "asc" : "desc"
    link_to label, project_reviews_path(project, sort: column, direction: direction, status: params[:status])
  end

  # Ostatnia aktywność = `updated_at`: każdy realny ruch (start review, followup,
  # decyzja, wykryty merge) idzie przez update!, a rutynowe stemplowanie GitHuba
  # świadomie omija timestampy (update_columns/update_all), więc szumu tu nie ma.
  # „dziś"/„wczoraj" zamiast gołej daty, bo pytanie brzmi „czy ruszałem to dzisiaj",
  # a nie „którego to było" — i tego z „29 Jul 14:03" nie odczytuje się wzrokiem.
  def review_last_activity(review)
    date = review.updated_at.to_date
    prefix = { Date.current => "dziś", Date.yesterday => "wczoraj" }[date]
    prefix ? "#{prefix} #{review.updated_at.strftime("%H:%M")}" : l(review.updated_at, format: :short)
  end

  # Trzeci stan jest tu sednem: „ścieżka w bazie, katalogu nie ma" znaczy, że worktree
  # zniknął poza dashboardem — followup wystartowałby w nieistniejącym katalogu, a nic
  # na liście tego nie zapowiadało.
  def worktree_badge(review)
    return tag.span("—", class: "wt-none", title: "Bez worktree — review pracuje w repo projektu") if review.own_worktree_path.blank?
    return tag.span("📁 jest", class: "wt-ok", title: review.own_worktree_path) if review.worktree_exists?

    tag.span("⚠ znikł", class: "wt-gone", title: "#{review.own_worktree_path} — tego katalogu już nie ma")
  end

  # Usunięcie review kasuje też jego worktree (katalog + baza devowa), więc confirm
  # musi wymienić branch z nazwy — inaczej user traci środowisko, nie wiedząc o tym.
  def review_destroy_confirm(review)
    return "Usunąć review i wszystkie artefakty? Tego nie da się cofnąć." unless review.own_worktree?

    "Usunąć review razem z artefaktami ORAZ worktree #{review.branch} (katalog i baza devowa)? Tego nie da się cofnąć."
  end

  # Treści z sesji Claude są w markdownie — renderujemy je do HTML zamiast
  # pokazywać surowe gwiazdki. Sanitize, bo to jednak wyjście modelu.
  def markdown(text)
    return "" if text.blank?

    html = Kramdown::Document.new(text, input: "GFM", hard_wrap: false).to_html
    tag.div(sanitize(html, tags: %w[p br strong em b i ul ol li h1 h2 h3 h4 code pre blockquote a table thead tbody tr th td hr],
                           attributes: %w[href]), class: "md")
  end

  # Log to surowy stream-json — wyciągamy z niego teksty asystenta, żeby user
  # widział CO Claude robił/napisał, a nie ścianę JSON-a.
  def claude_log_tail(review, limit: 3000)
    log_path = review.last_claude_run&.log_path
    return "brak logu" unless log_path && File.exist?(log_path)

    raw = File.read(log_path)
    texts = raw.lines.filter_map do |line|
      event = StreamJsonParser.parse_line(line)
      event.text if event && %i[assistant_text result].include?(event.type)
    end
    texts.any? ? texts.join("\n\n").last(limit) : raw.last(limit)
  end

  # Czas trwania sesji — przy kilku sesjach do wznowienia to jedyne, co odróżnia
  # tę z realną pracą od tej, która padła po kilku sekundach.
  def run_duration(run)
    return "—" unless run.started_at && run.finished_at

    seconds = (run.finished_at - run.started_at).round
    seconds < 60 ? "#{seconds} s" : "#{(seconds / 60.0).round} min"
  end

  # Skrót do rozbicia na sesje — pełne liczby czyta się tylko w wierszu podsumowania,
  # gdzie chodzi o dokładność, a nie o rzut oka. Skala do M jest konieczna: sesja
  # z dużą liczbą tur czyta z cache'u kilkanaście milionów tokenów, a „13416k"
  # nie jest liczbą, którą da się ogarnąć wzrokiem.
  def tokens_short(count)
    return "—" if count.blank?
    return count.to_s if count < 1000
    return "#{(count / 1000.0).round}k" if count < 1_000_000

    "#{number_with_precision(count / 1_000_000.0, precision: 1, separator: ",")}M"
  end

  # Aplikacja stoi na locale `en`, w którym separatorem tysięcy jest przecinek —
  # „289,135 tokenów" czyta się po polsku jak ułamek. Spacja jest jednoznaczna.
  def tokens_full(count) = number_with_delimiter(count, delimiter: " ")

  # Próg ostrzegawczy ma paść, zanim kolejny followup zdąży się nie zmieścić —
  # nie w momencie, gdy sesja już jest nie do uratowania.
  def ctx_level_class(percent)
    return "ctx-danger" if percent >= 85
    return "ctx-warn" if percent >= 60

    "ctx-ok"
  end

  # Compact pożycza status „reviewing", żeby dostać panel postępu i „Przerwij" —
  # bez tego panel pisałby „Review w toku" o kompakcji trwającej pół minuty.
  def in_progress_title(review)
    run = review.last_claude_run
    return "Kompaktuję sesję…" if run&.kind == "compact" && run.status.in?(%w[pending running])

    "Review w toku"
  end

  def decision_draft(review)
    parts = [ "## Review\n", review.summary.to_s, "\n" ]
    review.findings.order(:priority).each do |f|
      parts << "- **[#{f.priority}]** #{f.title} (#{f.file_location})"
    end
    parts.join("\n")
  end

  # Podpowiedź akcji po decyzji: PR bez żadnego review → zaproponuj drugiego
  # reviewera; ktoś już patrzył → zaproponuj label. Reguła tu, nie w ERB —
  # widok tylko renderuje jeden blok comboboxa.
  def followup_suggestion(review)
    reviewers = review.pr_reviewers_list
    if reviewers.any?
      { note: "Reviewowali: " + reviewers.map { |r| "#{r["login"]} (#{r["state"]})" }.join(", "),
        label: "🏷 Dodaj label po decyzji (opcjonalnie)", kind: "gh_label",
        field_name: "followup_label", initial: review.project.approve_label_default }
    else
      { note: "Nikt jeszcze nie reviewował tego PR-a.",
        label: "➕ Dodaj reviewera po decyzji (opcjonalnie)", kind: "gh_collaborator",
        field_name: "followup_reviewer", initial: review.project.second_reviewer_default }
    end
  end
end
