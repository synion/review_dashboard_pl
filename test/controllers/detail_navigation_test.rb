require "test_helper"

# Lista, review i formularz nowego review mają trzy wcielenia: wnętrze prawego panelu
# (zapytanie z ramki), pełny adres w układzie dwukolumnowym i pełny adres w układzie
# klasycznym. Ramka poza panelem zmieniała tylko treść, a nie adres — F5, filtr
# i „wstecz" lądowały wtedy na innej stronie niż ta, którą widać.
class DetailNavigationTest < ActionDispatch::IntegrationTest
  FRAME = { "Turbo-Frame" => "detail" }.freeze

  setup do
    @project = projects(:webapp)
    @project.update!(main_at: Time.current)
    @review = reviews(:pr_review)
  end

  test "pełna strona w układzie klasycznym nie owija treści w ramkę" do
    patch view_mode_path(mode: "classic")

    [ review_path(@review), project_reviews_path(@project), new_project_review_path(@project) ].each do |path|
      get path
      assert_response :success
      assert_select "turbo-frame#detail", count: 0, message: path
      assert_select ".dash-main", count: 0, message: path
    end
  end

  test "zapytanie z ramki dostaje samą ramkę, bez dashboardu" do
    [ review_path(@review), project_reviews_path(@project), new_project_review_path(@project) ].each do |path|
      get path, headers: FRAME
      assert_response :success
      assert_select "turbo-frame#detail", count: 1, message: path
      assert_select ".dash-main", count: 0, message: path
    end
  end

  # Wejście adresem (F5, „wstecz", link z czatu) ma wyglądać jak kliknięcie w panelu,
  # a nie wypadać z układu dwukolumnowego na osobną podstronę.
  test "pełny adres w układzie dwukolumnowym renderuje dashboard z wypełnionym panelem" do
    get review_path(@review)
    assert_select ".dash-main"
    assert_select ".dash-detail turbo-frame#detail[data-turbo-action=advance] h1", text: @review.headline

    get project_reviews_path(@project)
    assert_select ".dash-detail turbo-frame#detail table#reviews"

    get new_project_review_path(@project)
    assert_select ".dash-detail turbo-frame#detail form"
  end

  # Formularz bez action wysyłał się pod adres dokumentu — po nawigacji w ramce był
  # to adres review, stąd /reviews/88?status=… pokazujące review zamiast listy.
  test "filtr statusu wysyła się zawsze pod listę projektu i zachowuje sortowanie" do
    get project_reviews_path(@project, sort: "updated_at", direction: "asc"), headers: FRAME

    form = css_select("form.filter").first
    assert_equal project_reviews_path(@project), form["action"]
    assert_equal "get", form["method"]
    assert_select "form.filter input[type=hidden][name=sort][value=updated_at]"
    assert_select "form.filter input[type=hidden][name=direction][value=asc]"
    # submit() omija Turbo i przeładowuje całą stronę, gubiąc lewą kolumnę.
    assert_select "form.filter select[onchange*=requestSubmit]"
  end

  test "powrót z review prowadzi na listę z ostatnim filtrem i sortowaniem tego projektu" do
    get project_reviews_path(@project, status: "reviewed", sort: "updated_at", direction: "asc")
    get project_reviews_path(projects(:dashboard), status: "failed")

    get review_path(@review), headers: FRAME

    assert_select "a[href=?]", project_reviews_path(@project, direction: "asc", sort: "updated_at", status: "reviewed"),
                  text: "← wróć do listy"
  end

  test "powrót bez wcześniejszej wizyty na liście prowadzi na listę bez filtra" do
    get review_path(@review), headers: FRAME

    assert_select "a[href=?]", project_reviews_path(@project), text: "← wróć do listy"
  end

  # Błąd walidacji renderuje formularz z powrotem — pełnym zapytaniem w dwóch kolumnach
  # też z obudową, więc dane dashboardu muszą być załadowane i na tej ścieżce.
  test "błąd tworzenia review pełnym zapytaniem renderuje formularz w obudowie" do
    post project_reviews_path(@project), params: { review: { pr_url: @review.pr_url } }

    assert_response :unprocessable_entity
    assert_select ".dash-detail turbo-frame#detail form"
  end

  # Kopia strony z cache'u Turbo przy „wstecz" bywała kopią innego adresu.
  test "strony nie trafiają do cache'u Turbo" do
    get review_path(@review)

    assert_select "meta[name=turbo-cache-control][content=no-cache]"
  end
end
