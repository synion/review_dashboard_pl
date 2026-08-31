# Automat „zrób to za mnie" dla dwóch sygnałów, które i tak już wykrywamy:
# nowej prośby o review (kolejka z GitHuba) i PR-a wróconego po poprawkach
# (re-request wykryty przez CheckReviewRequestJob).
#
# Cała klasa to trzy bramki i zakolejkowanie istniejącego joba — świadomie NIC
# więcej: automat ma robić dokładnie to, co user klika ręcznie, tą samą drogą.
# Gdyby miał własną ścieżkę uruchamiania sesji, rozjechałaby się z ręczną przy
# pierwszej zmianie w cyklu review.
class AutoReview
  # Obszary review dla sesji odpalonej bez człowieka. Formularz startu zaznacza
  # domyślnie WSZYSTKIE (patrz reviews/_panel), ale qa_playwright odpala przeglądarkę
  # w trybie headed i pisze testy — to nie może wystartować samo, gdy nikt nie patrzy.
  AUTO_AREAS = (Review::AREAS.keys - [ "qa_playwright" ]).freeze
  # Uwaga otwierająca sesję followupu. Automat nie ma pytania od człowieka, więc
  # podaje sesji jedyne, co wie: autor zgłosił PR ponownie po decyzji.
  RETURNED_MESSAGE = "Autor zgłosił PR ponownie do review po Twojej decyzji. " \
                     "Sprawdź, co zmieniło się w kodzie od tamtej chwili, zweryfikuj poprzednie uwagi " \
                     "i zaktualizuj review (findings i podsumowanie)."

  # Nowe prośby o review z kolejki projektu → review założone i puszczone samo.
  # Wołane z RefreshInboxJob, czyli ZARAZ po przepisaniu kolejki: to jedyny moment,
  # w którym wiemy, że stan `inbox_items` odpowiada temu, co widzi GitHub.
  def self.create_for_requested(project)
    return 0 unless project.auto_review_requested? && !project.archived?

    # Tylko „requested": „commented" znaczy, że ktoś odezwał się po MOIM review —
    # tam review już jest, a jego ciąg dalszy to followup, nie nowe review.
    items = project.inbox_items.where(reason: "requested")
    existing = project.reviews.where(pr_number: items.map(&:pr_number)).pluck(:pr_number).to_set
    items.reject { |item| existing.include?(item.pr_number) }.count { |item| create_review(project, item) }
  end

  # Wołane z DescribeReviewJob, gdy review osiągnął `ready`. Warunek na status,
  # nie tylko na flagę: describe bywa ponawiany (retry_run, switch_config), a druga
  # sesja review nadpisałaby wynik pierwszej — dokładnie to, przed czym broni
  # guard w ReviewsController#start.
  def self.start_if_autostart(review)
    return false unless review.autostart? && review.status == "ready"

    # Kształt scope jak z formularza startu — panel czyta te same klucze.
    review.update!(scope: { "areas" => AUTO_AREAS, "notes" => "", "inline_comments" => true },
                   status: "reviewing")
    RunReviewJob.perform_later(review)
    true
  end

  # Wołane z CheckReviewRequestJob po wykryciu re-requestu. Status przestawiamy tu,
  # nie w jobie: między kolejkowaniem a workerem potrafi minąć kilkanaście minut,
  # a przez ten czas review wyglądałby jak czekający na kliknięcie człowieka.
  def self.followup_for_returned(review)
    return false unless review.project.auto_review_returned?
    return false unless Review::FOLLOWUPABLE_STATUSES.include?(review.status)

    review.update!(status: "reviewing")
    FollowupReviewJob.perform_later(review, RETURNED_MESSAGE)
    true
  end

  # Nieudany zapis nie może wywalić odświeżania kolejki: jeden PR spoza repo projektu
  # (albo wyścig z ręcznie założonym review) zablokowałby automat dla wszystkich
  # pozostałych pozycji.
  def self.create_review(project, item)
    review = project.reviews.new(pr_url: item.url, task_url: item.task_url, autostart: true,
                                 claude_config: project.default_claude_config,
                                 model: project.default_model, effort: project.default_effort)
    unless review.save
      Rails.logger.warn("AutoReview #{project.name} PR ##{item.pr_number}: #{review.errors.full_messages.to_sentence}")
      return false
    end

    DescribeReviewJob.perform_later(review)
    true
  end
  private_class_method :create_review
end
