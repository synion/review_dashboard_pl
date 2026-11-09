require "test_helper"

class DashboardTest < ActiveSupport::TestCase
  setup do
    @project = projects(:webapp)
    @project.update!(main_at: Time.current)
    inbox_items(:requested).update!(pr_labels: %w[KSeF])
    inbox_items(:commented).update!(pr_labels: %w[WIP])
  end

  def dashboard = Dashboard.new(main_project: @project.reload)

  test "bez filtra kolejka pokazuje wszystkie PR-y" do
    assert_equal [ [ 9001, 9002 ], 0 ], [ dashboard.inbox_items.map(&:pr_number), dashboard.hidden_inbox_count ]
  end

  test "filtr labelek zawęża kolejkę i liczy ukryte" do
    @project.update!(inbox_hidden_labels: %w[WIP])
    assert_equal [ [ 9001 ], 1 ], [ dashboard.inbox_items.map(&:pr_number), dashboard.hidden_inbox_count ]
  end

  test "opcje filtra to labelki z kolejki plus zapisane, nawet gdy zniknęły z GitHuba" do
    @project.update!(inbox_shown_labels: %w[stara])
    assert_equal %w[KSeF stara WIP], dashboard.inbox_label_options, "kolejność alfabetyczna bez względu na wielkość liter"
  end

  # PR ukryty filtrem nadal czeka na mnie w GitHubie — nie może „wypaść" do sekcji
  # „Rozpoczęte w dashboardzie", jakby był tylko moją robotą.
  test "review PR-a ukrytego filtrem nie wraca do sekcji Rozpoczęte" do
    reviews(:pr_review).update_columns(pr_url: "https://github.com/acme/webapp/pull/9002", pr_number: 9002,
                                       status: "reviewed")
    @project.update!(inbox_hidden_labels: %w[WIP])
    assert_not_includes dashboard.attention_reviews.map(&:pr_number), 9002
  end

  test "filtr „Odezwał się” chowa całą grupę, prośby o review zostają" do
    assert dashboard.inbox_commented_filter?
    @project.update!(inbox_hide_commented: true)
    assert_equal [ [ 9001 ], 1 ], [ dashboard.inbox_items.map(&:pr_number), dashboard.hidden_inbox_count ]
  end

  test "przełącznik „Odezwał się” niewidoczny bez tej grupy i bez włączonego filtra" do
    inbox_items(:commented).destroy
    assert_not dashboard.inbox_commented_filter?
    @project.update!(inbox_hide_commented: true)
    assert dashboard.inbox_commented_filter?, "włączony filtr musi dać się wyłączyć"
  end
end
