# Odpala jedną sesję headless Claude i mapuje strumień na stan ClaudeRun.
# Prompt idzie przez stdin — długie prompty nie mieszczą się w argv.
class ClaudeSessionRunner
  Failed = Class.new(StandardError)
  # Sesja zamilkła, choć proces żył. W odróżnieniu od zwykłego Failed warto ponowić —
  # to zwykle zacięcie samej sesji, a nie problem z zadaniem.
  Stalled = Class.new(Failed)

  COMMAND = %w[claude -p --verbose --output-format stream-json --dangerously-skip-permissions].freeze

  def initialize(claude_run, runner: CommandRunner)
    @run = claude_run
    @runner = runner
  end

  def call(prompt)
    FileUtils.mkdir_p(@run.review.artifacts_dir)
    # supervisor_pid = proces Ruby pilnujący sesji; po jego śmierci cleanup
    # wie, że run jest osierocony, nawet jeśli sam claude jeszcze żyje.
    @run.update!(status: "running", started_at: Time.current, supervisor_pid: Process.pid)
    final_text = nil

    File.open(@run.log_path, "a") do |log|
      result = @runner.stream(
        command,
        env: { "CLAUDE_CONFIG_DIR" => @run.claude_config },
        chdir: workdir,
        timeout: @run.timeout_seconds,
        idle_timeout: @run.idle_timeout_seconds,
        stdin_data: prompt,
        on_pid: ->(pid) { @run.update!(pid: pid) }
      ) do |line|
        log.write(line)
        final_text = handle_event(StreamJsonParser.parse_line(line)) || final_text
      end
      finalize(result, final_text)
    end

    final_text
  end

  private

  # --resume wznawia poprzednią sesję (pełny kontekst review) — używane przy
  # dyskusji z reviewerem (kind: followup). Model i effort z review, chyba że
  # run niesie własne (np. weryfikacja zasadności odpalona mocniejszym modelem).
  def command
    review = @run.review
    cmd = COMMAND.dup
    model = @run.model.presence || review.model
    effort = @run.effort.presence || review.effort
    cmd += [ "--model", model ] if model.present?
    cmd += [ "--effort", effort ] if effort.present?
    cmd += [ "--resume", @run.resume_session_id ] if @run.resume_session_id.present?
    cmd
  end

  def workdir
    @run.review.workdir
  end

  def handle_event(event)
    case event&.type
    when :init
      @run.update!(session_id: event.session_id)
      nil
    when :assistant_text
      # `text` bywa nil (wiadomość z samym tool_use) — nie wolno nim zamazać
      # ostatniego komunikatu, bo to on jest live tailem w panelu.
      attrs = {}
      attrs[:last_message] = event.text if event.text.present?
      attrs[:context_tokens] = event.context_tokens if event.context_tokens
      @run.update!(attrs) if attrs.any?
      nil
    when :result
      @run.update!(session_id: event.session_id || @run.session_id,
                   cost_usd: event.cost_usd, duration_ms: event.duration_ms,
                   # Okno przychodzi tylko z modelUsage; sesja przerwana wcześniej
                   # zostawia to, co wiadomo z poprzedniego pomiaru.
                   context_window: event.context_window || @run.context_window,
                   cache_read_tokens: event.cache_read_tokens,
                   cache_creation_tokens: event.cache_creation_tokens)
      event.text
    end
  end

  def finalize(result, final_text)
    if result.success? && final_text.present?
      @run.update!(finished_at: Time.current, status: "succeeded")
    else
      status, error_message, error_class =
        if result.idle_timed_out
          [ "aborted", "Cisza przez #{@run.idle_timeout_seconds}s — sesja zawisła", Stalled ]
        elsif result.timed_out
          [ "aborted", "Timeout po #{@run.timeout_seconds}s", Failed ]
        elsif result.signaled
          [ "aborted", "Przerwano ręcznie", Failed ]
        else
          # Powód porażki — wyczerpany limit konta, odmowa API — przychodzi jako ostatnia
          # wiadomość asystenta, nie na stderr. Bez niej w panelu zostaje samo „exit 1".
          [ "failed", result.stderr.last(2000).presence || @run.last_message.presence ||
            "Sesja zakończyła się bez tekstu końcowego (exit #{result.exit_code})", Failed ]
        end
      @run.update!(finished_at: Time.current, status: status, error_message: error_message)
      raise error_class, "Sesja Claude (#{@run.kind}) nie powiodła się: #{@run.error_message}"
    end
  end
end
