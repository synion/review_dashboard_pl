require "open3"

# Jedyne miejsce w aplikacji, które spawnuje procesy zewnętrzne.
# pgroup: true — przycisk „Przerwij" zabija cały process group jednym sygnałem.
# Celowo BEZ Timeout.timeout: przerwanie wątku w trakcie zapisu ActiveRecord
# (on_line robi update!) potrafi zostawić zablokowany mutex connection poola.
class CommandRunner
  KILL_GRACE = 3 # sekundy między SIGTERM a SIGKILL przy timeoucie
  POLL_INTERVAL = 1 # jak często sprawdzamy oba limity, czekając na koniec strumienia

  Result = Struct.new(:exit_code, :stdout, :stderr, :timed_out, :idle_timed_out, :signaled, keyword_init: true) do
    def success?
      exit_code == 0 && !timed_out && !idle_timed_out
    end
  end

  # Komendę shellową odpalamy przez NON-login zsh (-c). Login (-l) uruchamia
  # /etc/zprofile → path_helper, który przesuwa /usr/bin przed asdf shims i
  # wskrzesza systemowego Ruby 2.6 (asdf init siedzi tylko w .zshrc, którego
  # -lc i tak nie czyta). PATH i tak dostarczamy jawnie w subprocess_env.
  def self.zsh(script)
    [ "/bin/zsh", "-c", script ]
  end

  def self.stream(cmd, env: {}, chdir:, timeout:, idle_timeout: nil, stdin_data: nil, on_pid: nil, kill_grace: KILL_GRACE, &on_line)
    stdout_buf = +""
    stderr_buf = +""
    outcome = :done
    status = nil

    Open3.popen3(subprocess_env(env), *cmd, chdir: chdir, pgroup: true, unsetenv_others: true) do |stdin, stdout, stderr, wait_thr|
      on_pid&.call(wait_thr.pid)
      # stdin w osobnym wątku — synchroniczny write przed startem czytelników
      # deadlockuje, gdy dziecko zapełni bufor stdout zanim doczyta cały prompt.
      writer = Thread.new do
        stdin.write(stdin_data) if stdin_data
      rescue Errno::EPIPE
        # Dziecko zamknęło stdin wcześniej — reszta danych go nie interesuje.
      ensure
        begin
          stdin.close
        rescue IOError
          nil
        end
      end
      stderr_reader = Thread.new { stderr.each_line { |l| stderr_buf << l } }
      # Zapis skalara pod GVL jest atomowy — czytelnik tej zmiennej (pętla niżej)
      # potrzebuje tylko ostatniej wartości, więc mutex byłby tu zbędnym kosztem.
      last_line_at = monotonic
      stdout_reader = Thread.new do
        stdout.each_line do |line|
          last_line_at = monotonic
          stdout_buf << line
          on_line&.call(line)
        end
      end

      outcome = watch(stdout_reader, timeout: timeout, idle_timeout: idle_timeout) { last_line_at }
      unless outcome == :done
        kill_group(wait_thr.pid)
        # Grace na TERM; proces ignorujący sygnał dobijamy KILL-em, żeby nie
        # zawiesić wątku workera na zawsze.
        unless stdout_reader.join(kill_grace)
          kill_group(wait_thr.pid, signal: "KILL")
          stdout_reader.join(5)
        end
      end
      writer.join(5)
      stderr_reader.join(5)
      status = wait_thr.join(10)&.value
    end

    Result.new(
      exit_code: status&.exitstatus || -1,
      stdout: stdout_buf, stderr: stderr_buf,
      timed_out: outcome == :timeout, idle_timed_out: outcome == :idle,
      signaled: !!status&.signaled?
    )
  end

  # Czeka na koniec strumienia, pilnując dwóch limitów naraz: całkowitego czasu
  # i ciszy. Zwisająca sesja przestaje emitować linie, choć proces żyje — czekanie
  # na limit całkowity byłoby wtedy tylko marnowaniem czasu.
  def self.watch(reader, timeout:, idle_timeout:, &last_line_at)
    started = monotonic
    until reader.join(POLL_INTERVAL)
      now = monotonic
      return :timeout if now - started >= timeout
      return :idle if idle_timeout && now - last_line_at.call >= idle_timeout
    end
    :done
  end
  private_class_method :watch

  def self.monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
  private_class_method :monotonic

  def self.run(cmd, env: {}, chdir:, timeout: 600, stdin_data: nil)
    stream(cmd, env: env, chdir: chdir, timeout: timeout, stdin_data: stdin_data)
  end

  def self.kill_group(pid, signal: "TERM")
    Process.kill(signal, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    # Proces już nie żyje — nic do zrobienia.
  end

  # Środowisko subprocesu budujemy jawnie i odcinamy dziedziczenie (unsetenv_others
  # w popen3). Dashboard działa pod bundlerem, więc jego ENV ma RUBYOPT=-rbundler/setup
  # i GEM_HOME/GEM_PATH wskazujące gemy 3.4.7. Wpuszczone do subprocesu wymuszały
  # ładowanie bundlera 3.4 pod systemowym Ruby 2.6 → NameError. unbundled_env oddaje
  # środowisko sprzed bundlera (bez tych zmiennych) — używamy tej wersji, NIE
  # with_unbundled_env, bo workery SolidQueue są wielowątkowe i mutacja globalnego
  # ENV to race. Do tego asdf shims na czele PATH → `ruby`/`bin/rails` w innym repo
  # rozwiązują się wg jego .ruby-version, a nie do systemowego Ruby 2.6.
  def self.subprocess_env(extra)
    base = Bundler.unbundled_env
    base["PATH"] = asdf_shims_first(base["PATH"])
    base.merge(extra.transform_keys(&:to_s))
  end

  # Walidacja komend w Project pyta o TEN SAM PATH, w którym komenda realnie
  # ruszy — PATH procesu Rails (zbundlowany, bez shims na czele) bywa inny.
  def self.executable_in_path?(name)
    subprocess_env({})["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
      path = File.join(dir, name)
      File.file?(path) && File.executable?(path)
    end
  end

  def self.asdf_shims_first(path)
    parts = path.to_s.split(File::PATH_SEPARATOR)
    shims = parts.find { |p| p.end_with?("/.asdf/shims") } || File.join(Dir.home, ".asdf", "shims")
    ([ shims ] + parts).uniq.join(File::PATH_SEPARATOR)
  end
end
