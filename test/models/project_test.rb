require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  # Tymczasowe "repo" z wykonywalnym bin/worktree — testy walidacji komend
  # nie mogą zależeć od prawdziwych repozytoriów na dysku dewelopera.
  def with_fake_repo
    Dir.mktmpdir do |repo|
      script = File.join(repo, "bin", "worktree")
      FileUtils.mkdir_p(File.dirname(script))
      File.write(script, "#!/bin/bash\n")
      FileUtils.chmod(0o755, script)
      yield repo
    end
  end

  test "odrzuca config Claude spoza listy dostępnych" do
    project = projects(:webapp)
    project.default_claude_config = "/etc/passwd"
    assert_not project.valid?
    assert_includes project.errors[:default_claude_config], "nie jest jednym z dostępnych configów"
  end

  # `inclusion` bez allow_blank już samo wymusza obecność (nil/"" nie ma na liście) —
  # osobne `presence` dawało dwa komunikaty błędu na to samo puste pole.
  test "puste default_claude_config daje jeden komunikat błędu, nie dwa" do
    project = projects(:webapp)
    project.default_claude_config = ""
    assert_not project.valid?
    assert_equal 1, project.errors[:default_claude_config].size
  end

  # Nazwa identyfikuje projekt na liście i w nagłówkach — duplikat sprawiłby,
  # że dwóch pozycji nie da się odróżnić.
  test "nazwa projektu musi być unikalna" do
    duplicate = Project.new(projects(:webapp).attributes.except("id", "created_at", "updated_at"))
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "przyjmuje config Claude z listy" do
    project = projects(:webapp)
    project.default_claude_config = "/Users/dev/.claude-b"
    assert project.valid?, project.errors.full_messages.to_sentence
  end

  test "odrzuca model i effort spoza list, przyjmuje puste" do
    project = projects(:webapp)
    project.default_model = "gpt"
    assert_not project.valid?

    project.default_model = "opus"
    project.default_effort = "kosmiczny"
    assert_not project.valid?

    project.default_effort = ""
    assert project.valid?, project.errors.full_messages.to_sentence
  end

  test "github_slug wyciąga owner i repo z adresu repozytorium" do
    project = projects(:webapp)

    project.repo_url = "https://github.com/acme/webapp"
    assert_equal "acme/webapp", project.github_slug

    project.repo_url = "https://github.com/acme/webapp.git"
    assert_equal "acme/webapp", project.github_slug

    project.repo_url = "https://github.com/acme/webapp/"
    assert_equal "acme/webapp", project.github_slug
  end

  test "github_slug jest puste, gdy projekt nie ma adresu repozytorium" do
    project = projects(:webapp)
    project.repo_url = ""
    assert_nil project.github_slug
    assert project.valid?, project.errors.full_messages.to_sentence
  end

  test "odrzuca adres repozytorium spoza GitHuba" do
    project = projects(:webapp)
    project.repo_url = "https://gitlab.com/acme/webapp"
    assert_not project.valid?
  end

  # `format` na złym wzorcu rzuca KeyError/TypeError, nie WorktreeManager::Error —
  # a to jedyna klasa, którą łapie Review#remove_worktree. Bez tej walidacji zła
  # literówka w formularzu wychodzi na jaw dopiero przy próbie usunięcia review,
  # już po skasowaniu jego artefaktów.
  test "odrzuca komendę worktree z literówką w nazwie klucza %{branch}" do
    project = projects(:webapp)
    project.worktree_command = "bin/wt %{brnach}"
    assert_not project.valid?
    assert_includes project.errors[:worktree_command].to_sentence, "%{branch}"
  end

  test "odrzuca komendę worktree z gołym znakiem procenta" do
    project = projects(:webapp)
    project.worktree_delete_command = "echo 50% off %{branch}"
    assert_not project.valid?
    assert_includes project.errors[:worktree_delete_command].to_sentence, "%{branch}"
  end

  # projects(:dashboard) — jedyny fixture z istniejącym repo_path, a walidacja
  # worktree_executables_exist czyta dysk przy zmianie komendy.
  test "przyjmuje komendę worktree z podwojonym procentem (%%)" do
    project = projects(:dashboard)
    project.worktree_command = "echo 50%% off %{branch}"
    assert project.valid?, project.errors.full_messages.to_sentence
  end

  # Realny przypadek: komenda skopiowana z innego projektu (bin/worktree-docker),
  # a w repo skrypt nazywa się bin/worktree — bez walidacji błąd wychodził dopiero
  # przy pierwszym review, jako failed z "no such file or directory".
  test "odrzuca worktree_command ze skryptem, którego nie ma w repo, i podpowiada podobny" do
    with_fake_repo do |repo|
      project = projects(:dashboard)
      project.repo_path = repo
      project.worktree_command = "bin/worktree-docker %{branch}"

      assert_not project.valid?
      message = project.errors[:worktree_command].to_sentence
      assert_includes message, "bin/worktree-docker"
      assert_includes message, "może chodziło o bin/worktree?"
    end
  end

  test "przyjmuje worktree_command ze skryptem istniejącym w repo" do
    with_fake_repo do |repo|
      project = projects(:dashboard)
      project.repo_path = repo
      project.worktree_command = "bin/worktree %{branch}"
      project.worktree_delete_command = "bin/worktree -d %{branch} --force"

      assert project.valid?, project.errors.full_messages.to_sentence
    end
  end

  test "przyjmuje komendę z programem dostępnym w PATH" do
    project = projects(:dashboard)
    project.worktree_command = "git worktree add ../x-%{branch} %{branch}"

    assert project.valid?, project.errors.full_messages.to_sentence
  end

  test "odrzuca komendę z programem, którego nie ma w PATH" do
    project = projects(:dashboard)
    project.worktree_command = "nieistniejacy-program-xyz %{branch}"

    assert_not project.valid?
    assert_includes project.errors[:worktree_command].to_sentence, "nieistniejacy-program-xyz"
  end

  test "odrzuca repo_path, którego nie ma na dysku" do
    project = projects(:dashboard)
    project.repo_path = "/nie/ma/takiego/katalogu"

    assert_not project.valid?
    assert_includes project.errors[:repo_path], "nie istnieje na dysku"
  end

  test "scope active i archived rozdzielają projekty po archived_at" do
    archived = projects(:dashboard)
    archived.update!(archived_at: Time.current)

    assert_includes Project.active, projects(:webapp)
    assert_not_includes Project.active, archived
    assert_includes Project.archived, archived
    assert archived.archived?
    assert_not projects(:webapp).archived?
  end
end
