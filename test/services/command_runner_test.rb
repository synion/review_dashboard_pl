require "test_helper"

class CommandRunnerTest < ActiveSupport::TestCase
  test "stream oddaje linie stdout do bloku i wynik" do
    lines = []
    result = CommandRunner.stream([ "/bin/sh", "-c", "echo a; echo b" ], chdir: Dir.tmpdir, timeout: 5) { |l| lines << l.chomp }
    assert_equal({ lines: %w[a b], exit_code: 0, success: true, timed_out: false },
                 { lines: lines, exit_code: result.exit_code, success: result.success?, timed_out: result.timed_out })
  end

  test "run zbiera stderr i kod wyjścia" do
    result = CommandRunner.run([ "/bin/sh", "-c", "echo err >&2; exit 3" ], chdir: Dir.tmpdir)
    assert_equal({ exit_code: 3, stderr: "err\n", success: false }, { exit_code: result.exit_code, stderr: result.stderr, success: result.success? })
  end

  test "stdin_data trafia do procesu" do
    result = CommandRunner.run([ "/bin/cat" ], chdir: Dir.tmpdir, stdin_data: "hello")
    assert_equal "hello", result.stdout
  end

  test "timeout zabija proces i oznacza timed_out" do
    started = Time.current
    result = CommandRunner.run([ "/bin/sh", "-c", "sleep 30" ], chdir: Dir.tmpdir, timeout: 1)
    assert result.timed_out
    assert_not result.success?
    assert_operator Time.current - started, :<, 10
  end

  # Zwis sesji Claude to cisza w strumieniu przy żywym procesie — bez tego watchdoga
  # trzeba było czekać na pełny limit (i tak nie doczekać wyniku).
  test "cisza dłuższa niż idle_timeout ubija proces i oznacza idle_timed_out" do
    started = Time.current
    result = CommandRunner.stream([ "/bin/sh", "-c", "echo start; sleep 30" ], chdir: Dir.tmpdir, timeout: 60, idle_timeout: 1) { }
    assert_equal({ idle: true, timed_out: false, success: false },
                 { idle: result.idle_timed_out, timed_out: result.timed_out, success: result.success? })
    assert_operator Time.current - started, :<, 15
  end

  test "proces gadający regularnie nie jest ubijany mimo krótkiego idle_timeout" do
    result = CommandRunner.stream([ "/bin/sh", "-c", "for i in 1 2 3 4 5 6; do echo $i; sleep 0.5; done" ],
                                  chdir: Dir.tmpdir, timeout: 60, idle_timeout: 2) { }
    assert_equal({ idle: false, success: true, lines: 6 },
                 { idle: result.idle_timed_out, success: result.success?, lines: result.stdout.lines.size })
  end

  test "limit całkowity wygrywa z idle gdy proces gada bez końca" do
    result = CommandRunner.stream([ "/bin/sh", "-c", "while :; do echo x; sleep 0.2; done" ],
                                  chdir: Dir.tmpdir, timeout: 2, idle_timeout: 30) { }
    assert_equal({ timed_out: true, idle: false }, { timed_out: result.timed_out, idle: result.idle_timed_out })
  end

  test "bez idle_timeout watchdog ciszy nie działa" do
    result = CommandRunner.stream([ "/bin/sh", "-c", "echo a; sleep 2; echo b" ], chdir: Dir.tmpdir, timeout: 30) { }
    assert_equal({ idle: false, success: true }, { idle: result.idle_timed_out, success: result.success? })
  end

  test "on_pid dostaje pid działającego procesu" do
    seen_pid = nil
    CommandRunner.stream([ "/bin/sh", "-c", "echo x" ], chdir: Dir.tmpdir, timeout: 5, on_pid: ->(pid) { seen_pid = pid }) { }
    assert_kind_of Integer, seen_pid
  end

  test "duży stdin nie deadlockuje gdy dziecko od razu pisze na stdout" do
    data = "x" * 1_000_000
    result = CommandRunner.run([ "/bin/cat" ], chdir: Dir.tmpdir, stdin_data: data, timeout: 15)
    assert_equal({ success: true, bytes: data.bytesize }, { success: result.success?, bytes: result.stdout.bytesize })
  end

  test "proces ignorujący TERM jest dobijany KILL-em po grace" do
    started = Time.current
    result = CommandRunner.stream([ "/bin/sh", "-c", 'trap "" TERM; sleep 30' ], chdir: Dir.tmpdir, timeout: 1, kill_grace: 1) { }
    assert result.timed_out
    assert_operator Time.current - started, :<, 15
  end

  test "proces ubity sygnałem ma signaled=true" do
    result = CommandRunner.run([ "/bin/sh", "-c", "kill -TERM $$" ], chdir: Dir.tmpdir, timeout: 5)
    assert_equal({ signaled: true, success: false }, { signaled: result.signaled, success: result.success? })
  end

  # Regresja: dashboard działa pod bundlerem (RUBYOPT=-rbundler/setup). Bez
  # izolacji env ten RUBYOPT przeciekał do subprocesu i wymuszał ładowanie
  # bundlera 3.4 pod systemowym Ruby 2.6 → NameError. Subprocess NIE może
  # widzieć env bundlera dashboardu.
  test "subprocess nie dziedziczy env bundlera dashboardu" do
    result = CommandRunner.run([ "/bin/sh", "-c", "echo RUBYOPT=${RUBYOPT:-none}; echo BUNDLE_GEMFILE=${BUNDLE_GEMFILE:-none}" ], chdir: Dir.tmpdir)
    assert_equal "RUBYOPT=none\nBUNDLE_GEMFILE=none\n", result.stdout
  end

  # asdf shims muszą być na czele PATH, żeby `ruby`/`bin/rails` w worktree
  # rozwiązywały się przez .ruby-version katalogu, a nie do systemowego Ruby 2.6.
  test "subprocess dostaje asdf shims na przedzie PATH" do
    result = CommandRunner.run([ "/bin/sh", "-c", "echo $PATH" ], chdir: Dir.tmpdir)
    assert_match %r{\A[^:]*/\.asdf/shims(:|\z)}, result.stdout.strip
  end

  # zsh NON-login (-c): login (-l) odpala /etc/zprofile → path_helper, który
  # przesuwa /usr/bin przed asdf shims i wskrzesza systemowego Ruby 2.6.
  test "zsh buduje non-login shell" do
    assert_equal [ "/bin/zsh", "-c", "echo hi" ], CommandRunner.zsh("echo hi")
  end

  test "extra env nadpisuje bazowe i trafia do procesu" do
    result = CommandRunner.run([ "/bin/sh", "-c", "echo $FOO" ], env: { "FOO" => "bar" }, chdir: Dir.tmpdir)
    assert_equal "bar\n", result.stdout
  end
end
