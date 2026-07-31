# Worktree tworzymy WYŁĄCZNIE komendą projektu (bin/worktree-docker) — surowy
# `git worktree add` nie kopiuje configów i nie stawia bazy.
class WorktreeManager
  Error = Class.new(StandardError)

  CREATE_TIMEOUT = 1800 # bin/worktree-docker stawia bazę — bywa długie

  def initialize(project, runner: CommandRunner)
    @project = project
    @runner = runner
  end

  def ensure_for_branch(branch)
    find_existing(branch) || create(branch)
  end

  # Usuwanie TYLKO na wyraźne kliknięcie z dashboardu — nigdy automatycznie.
  def remove(branch)
    command = format(@project.worktree_delete_command, branch: branch)
    run!(CommandRunner.zsh(command), label: command)
  end

  def checkout_pr(worktree_path, pr_url)
    run!([ "gh", "pr", "checkout", pr_url ], label: "gh pr checkout", chdir: worktree_path)
  end

  # Branche istniejących worktree — podpowiedzi w formularzu nowego review.
  # Bez głównego checkoutu (to nie jest praca do review) i bez detached HEAD.
  # Miękka degradacja do []: formularz ma się otworzyć także przy zepsutym repo,
  # a błąd i tak wyjdzie przy próbie użycia worktree.
  def existing_branches
    result = run!([ "git", "worktree", "list", "--porcelain" ], label: "git worktree list")

    result.stdout.split("\n\n").filter_map { |entry|
      lines = entry.lines.map(&:chomp)
      next if lines.first == "worktree #{@project.repo_path}"

      lines.find { |line| line.start_with?("branch refs/heads/") }
           &.delete_prefix("branch refs/heads/")
    }.sort
  rescue Error, SystemCallError
    # SystemCallError: nieistniejący repo_path wywala już samo spawnowanie procesu
    # (ENOENT z chdir), zanim git zdąży cokolwiek powiedzieć.
    []
  end

  private

  # Odpala komendę i rzuca Error z jej stderr gdy się nie powiedzie —
  # ten sam wzorzec powtarzał się przy każdym wywołaniu @runner.run.
  def run!(cmd, label:, chdir: @project.repo_path, **opts)
    result = @runner.run(cmd, chdir: chdir, **opts)
    raise Error, "#{label}: #{result.stderr}" unless result.success?

    result
  end

  def find_existing(branch)
    result = run!([ "git", "worktree", "list", "--porcelain" ], label: "git worktree list")

    entries = result.stdout.split("\n\n")
    entry = entries.find { |e| e.lines.map(&:chomp).include?("branch refs/heads/#{branch}") }
    entry&.lines&.first&.delete_prefix("worktree ")&.strip
  end

  def create(branch)
    command = format(@project.worktree_command, branch: branch)
    run!(CommandRunner.zsh(command), label: command, timeout: CREATE_TIMEOUT)

    find_existing(branch) || raise(Error, "Worktree dla #{branch} nie powstał mimo sukcesu komendy")
  end
end
