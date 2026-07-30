# Diagnostyka zacięć workera solid_queue. 27 lipca 2026 worker przestał podejmować
# joby i bić heartbeat na ~7 minut, po czym wrócił sam — bez zajrzenia do wnętrza
# procesu nie dało się orzec, czy stała cała maszyna, czy tylko pętla pollingu.
#
# Watchdog celowo nie odpytuje bazy: liczniki puli połączeń czyta z pamięci, więc
# nie zablokuje się na tym samym, co diagnozuje. Jego własne milczenie w logu też
# jest dowodem — znaczy, że proces nie dostawał czasu procesora.
class WorkerStallWatchdog
  INTERVAL = 30

  def self.start(interval: INTERVAL, logger: default_logger)
    Thread.new do
      Thread.current.name = "worker-stall-watchdog"
      new(logger: logger, interval: interval).run
    end
  end

  # Osobny plik, żeby oś czasu zacięcia nie ginęła w ścianie development.log.
  def self.default_logger
    Logger.new(Rails.root.join("log", "worker_stall.log"), 3, 5_000_000)
  end

  def initialize(logger:, interval: INTERVAL)
    @logger = logger
    @interval = interval
  end

  def run
    loop do
      before = monotonic
      sleep(@interval)
      tick(lag: monotonic - before - @interval)
    end
  end

  # lag = o ile spóźnił się własny tik. Sen 30 s, który trwał 6 minut, znaczy, że
  # proces nie dostawał czasu — stała cała maszyna, a nie sama pętla pollingu.
  def tick(lag:)
    @logger.info(report(lag))
    @logger.info(thread_dump) if stalled?(lag)
  end

  private

  def stalled?(lag) = lag > @interval

  def report(lag)
    [ "pid=#{Process.pid}", "wątki=#{Thread.list.count(&:alive?)}", "opóźnienie=#{lag.round(1)}s",
      pool_stat("primary", ActiveRecord::Base), pool_stat("queue", SolidQueue::Record) ].join(" ")
  end

  # busy/size + waiting: wyczerpana pula przy pełnej kolejce oczekujących to
  # najprostsze wyjaśnienie zamarłego heartbeatu, więc musi być widoczne od razu.
  def pool_stat(label, klass)
    stat = klass.connection_pool.stat
    "#{label}=#{stat[:busy]}/#{stat[:size]} czeka=#{stat[:waiting]}"
  end

  def thread_dump
    lines = [ "ZAMROŻENIE — zrzut stosów (#{Thread.list.size} wątków):" ]
    Thread.list.each do |thread|
      lines << "  [#{thread.name || thread.object_id}] status=#{thread.status}"
      Array(thread.backtrace).first(12).each { |frame| lines << "    #{frame}" }
    end
    lines.join("\n")
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
