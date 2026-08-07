require "test_helper"

class ViewModesControllerTest < ActionDispatch::IntegrationTest
  # Domyślnie dwie kolumny: kto nic nie klikał, dostaje układ master–detail.
  test "strona wejściowa bez ciasteczka renderuje układ dwukolumnowy" do
    get root_path

    assert_select ".dash-detail"
    assert_select "turbo-frame#detail"
  end

  test "tryb klasyczny zdejmuje prawą kolumnę i cel ramki z kafli" do
    patch view_mode_path(mode: "classic")

    get root_path

    assert_select ".dash-detail", count: 0
    assert_select "turbo-frame#detail", count: 0
    assert_select "a[data-turbo-frame]", count: 0
  end

  test "powrót do dwóch kolumn" do
    patch view_mode_path(mode: "classic")
    patch view_mode_path(mode: "split")

    get root_path

    assert_select ".dash-detail"
  end

  # Wartość z adresu trafia prosto do ciasteczka czytanego przez widoki — bez tego
  # wystarczyłby jeden link, żeby wstrzyknąć w nie cokolwiek.
  test "nieznany tryb spada do domyślnego" do
    patch view_mode_path(mode: "<script>")

    get root_path

    assert_equal "split", cookies[:view_mode]
    assert_select ".dash-detail"
  end

  test "wraca tam, skąd przyszedł" do
    patch view_mode_path(mode: "classic"), headers: { "HTTP_REFERER" => project_reviews_url(projects(:webapp)) }

    assert_redirected_to project_reviews_url(projects(:webapp))
  end
end
