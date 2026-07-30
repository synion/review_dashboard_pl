require "test_helper"

class SessionMigratorTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir
    @firm = File.join(@root, "firm")
    @pryw = File.join(@root, "pryw")
    @review = reviews(:pr_review)
    @review.update!(worktree_path: "/wt")
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  def run_with_session(session_id, kind: "review")
    run = @review.claude_runs.create!(kind: kind, claude_config: @firm, status: "succeeded", session_id: session_id)
    path = run.session_file
    FileUtils.mkdir_p(path.dirname)
    File.write(path, %({"session_id":"#{session_id}"}\n))
    run
  end

  test "kopiuje plik sesji pod nowy config i zostawia oryginał" do
    run = run_with_session("sess-1")
    assert_equal 1, SessionMigrator.new(@review).migrate_to(@pryw)
    assert_equal %({"session_id":"sess-1"}\n), File.read(run.session_file(@pryw))
    assert File.exist?(run.session_file(@firm)), "oryginał musi zostać — przełączenie ma być odwracalne"
  end

  test "kopiuje też katalog z tool-results, na który powołuje się transkrypt" do
    run = run_with_session("sess-1")
    tools = run.session_file.dirname.join("sess-1", "tool-results")
    FileUtils.mkdir_p(tools)
    File.write(tools.join("out.txt"), "duży wynik")
    SessionMigrator.new(@review).migrate_to(@pryw)
    assert_equal "duży wynik", File.read(run.session_file(@pryw).dirname.join("sess-1", "tool-results", "out.txt"))
  end

  test "brak pliku źródłowego nie przerywa migracji pozostałych sesji" do
    sprzatnieta = run_with_session("sess-1")
    FileUtils.rm(sprzatnieta.session_file)
    zywa = run_with_session("sess-2")
    assert_equal 1, SessionMigrator.new(@review).migrate_to(@pryw)
    assert File.exist?(zywa.session_file(@pryw))
  end

  # Powrót na konto, z którego sesja pochodzi: source i target to ten sam plik.
  # Bez pominięcia FileUtils.cp rzuca ArgumentError i przycisk powrotu jest trwale
  # zepsuty dla każdego review, które raz już przełączono.
  test "sesja leżąca już pod configiem docelowym jest pomijana bez wyjątku" do
    run = run_with_session("sess-1")
    assert_equal 0, SessionMigrator.new(@review).migrate_to(@firm)
    assert_equal %({"session_id":"sess-1"}\n), File.read(run.session_file(@firm)), "plik ma zostać nietknięty"
  end

  test "przełączenie tam i z powrotem zostawia sesję na obu kontach" do
    run = run_with_session("sess-1")
    assert_equal 1, SessionMigrator.new(@review).migrate_to(@pryw)
    # update_column: @pryw to tmpdir testowy, nie jeden z configów z listy —
    # walidacja inclusion na claude_config nie ma tu czego pilnować.
    @review.update_column(:claude_config, @pryw)
    assert_equal 0, SessionMigrator.new(@review).migrate_to(@firm)
    assert File.exist?(run.session_file(@firm))
    assert File.exist?(run.session_file(@pryw))
  end

  test "runy bez session_id są pomijane" do
    @review.claude_runs.create!(kind: "describe", claude_config: @firm, status: "failed")
    assert_equal 0, SessionMigrator.new(@review).migrate_to(@pryw)
  end
end
