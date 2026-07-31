require "test_helper"

class ClaudeSessionRunnerTest < ActiveSupport::TestCase
  # Fake CommandRunner: oddaje przygotowane linie stream-json i wynik.
  class FakeRunner
    attr_reader :calls

    def initialize(lines:, exit_code: 0, timed_out: false, stderr: "boom")
      @lines = lines
      @exit_code = exit_code
      @timed_out = timed_out
      @stderr = stderr
      @calls = []
    end

    def stream(cmd, env:, chdir:, timeout:, idle_timeout: nil, stdin_data: nil, on_pid: nil, &block)
      @calls << { cmd: cmd, env: env, chdir: chdir, timeout: timeout, idle_timeout: idle_timeout, stdin_data: stdin_data }
      on_pid&.call(4242)
      @lines.each { |l| block.call(l + "\n") }
      CommandRunner::Result.new(exit_code: @exit_code, stdout: "", stderr: @stderr, timed_out: @timed_out)
    end
  end

  setup do
    @review = reviews(:pr_review)
    @review.update!(worktree_path: Dir.tmpdir)
    @run = @review.claude_runs.create!(kind: "describe", claude_config: "/Users/dev/.claude")
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  test "happy path: zapisuje session_id, koszt, status i zwraca tekst końcowy" do
    fake = FakeRunner.new(lines: [
      { type: "system", subtype: "init", session_id: "sess-9" }.to_json,
      { type: "assistant", message: { content: [ { type: "text", text: "Czytam PR" } ] } }.to_json,
      { type: "result", subtype: "success", session_id: "sess-9", total_cost_usd: 0.5, duration_ms: 1000, result: "OPIS" }.to_json
    ])
    result = ClaudeSessionRunner.new(@run, runner: fake).call("prompt treść")
    @run.reload
    assert_equal(
      { result: "OPIS", session_id: "sess-9", status: "succeeded", pid: 4242,
        cost_usd: 0.5, duration_ms: 1000, last_message: "Czytam PR" },
      { result: result, session_id: @run.session_id, status: @run.status, pid: @run.pid,
        cost_usd: @run.cost_usd.to_f, duration_ms: @run.duration_ms, last_message: @run.last_message }
    )
    call = fake.calls.first
    assert_equal({ "CLAUDE_CONFIG_DIR" => "/Users/dev/.claude" }, call[:env])
    assert_equal "prompt treść", call[:stdin_data]
    assert_equal Dir.tmpdir, call[:chdir]
    assert_equal %w[claude -p --verbose --output-format stream-json --dangerously-skip-permissions], call[:cmd]
    assert File.read(@run.log_path).include?("sess-9")
  end

  test "niezerowy exit code oznacza failed i rzuca Failed" do
    fake = FakeRunner.new(lines: [], exit_code: 1)
    error = assert_raises(ClaudeSessionRunner::Failed) { ClaudeSessionRunner.new(@run, runner: fake).call("x") }
    assert_equal "failed", @run.reload.status
    assert_includes error.message, "boom"
  end

  test "sukces bez tekstu końcowego daje failed z czytelnym komunikatem" do
    fake = FakeRunner.new(lines: [], exit_code: 0)
    assert_raises(ClaudeSessionRunner::Failed) { ClaudeSessionRunner.new(@run, runner: fake).call("x") }
    @run.reload
    assert_equal "failed", @run.status
    assert_includes @run.error_message, "boom"
  end

  test "sukces bez tekstu i bez stderr daje komunikat o braku odpowiedzi" do
    fake = FakeRunner.new(lines: [], exit_code: 0)
    fake.define_singleton_method(:stream) do |*args, **kwargs, &block|
      CommandRunner::Result.new(exit_code: 0, stdout: "", stderr: "", timed_out: false)
    end
    assert_raises(ClaudeSessionRunner::Failed) { ClaudeSessionRunner.new(@run, runner: fake).call("x") }
    assert_includes @run.reload.error_message, "bez tekstu końcowego"
  end

  # Wyczerpany limit konta przychodzi jako ostatnia wiadomość asystenta, nie na
  # stderr — bez niej panel pokazuje tylko „exit 1" i nie da się zgadnąć przyczyny.
  test "porażka bez stderr pokazuje ostatnią wiadomość sesji jako powód" do
    fake = FakeRunner.new(lines: [
      { type: "assistant", message: { content: [ { type: "text", text: "You've hit your org's monthly spend limit" } ] } }.to_json
    ], exit_code: 1, stderr: "")
    assert_raises(ClaudeSessionRunner::Failed) { ClaudeSessionRunner.new(@run, runner: fake).call("x") }
    assert_includes @run.reload.error_message, "monthly spend limit"
  end

  test "timeout oznacza aborted" do
    fake = FakeRunner.new(lines: [], exit_code: -1, timed_out: true)
    assert_raises(ClaudeSessionRunner::Failed) { ClaudeSessionRunner.new(@run, runner: fake).call("x") }
    assert_equal "aborted", @run.reload.status
  end

  # Zwis musi być odróżnialny od zwykłej porażki — tylko jego RunReviewJob ponawia.
  test "cisza w strumieniu daje Stalled i aborted z czytelnym komunikatem" do
    fake = FakeRunner.new(lines: [], exit_code: -1)
    fake.define_singleton_method(:stream) do |*_args, **_kwargs, &_block|
      CommandRunner::Result.new(exit_code: -1, stdout: "", stderr: "", idle_timed_out: true)
    end
    assert_raises(ClaudeSessionRunner::Stalled) { ClaudeSessionRunner.new(@run, runner: fake).call("x") }
    @run.reload
    assert_equal "aborted", @run.status
    assert_includes @run.error_message, "Cisza"
  end

  test "sesja dostaje limit ciszy z modelu" do
    fake = FakeRunner.new(lines: [
      { type: "result", subtype: "success", session_id: "s", total_cost_usd: 0.1, duration_ms: 5, result: "OK" }.to_json
    ])
    ClaudeSessionRunner.new(@run, runner: fake).call("x")
    assert_equal @run.idle_timeout_seconds, fake.calls.first[:idle_timeout]
  end

  test "ręczne przerwanie sygnałem oznacza aborted z czytelnym komunikatem" do
    fake = FakeRunner.new(lines: [], exit_code: -1)
    fake.define_singleton_method(:stream) do |*_args, **_kwargs, &_block|
      CommandRunner::Result.new(exit_code: -1, stdout: "", stderr: "", timed_out: false, signaled: true)
    end
    assert_raises(ClaudeSessionRunner::Failed) { ClaudeSessionRunner.new(@run, runner: fake).call("x") }
    @run.reload
    assert_equal({ status: "aborted", error: "Przerwano ręcznie" }, { status: @run.status, error: @run.error_message })
  end

  test "model i effort z review trafiają do komendy" do
    @review.update!(model: "sonnet", effort: "high")
    fake = FakeRunner.new(lines: [
      { type: "result", subtype: "success", session_id: "s", total_cost_usd: 0.1, duration_ms: 5, result: "OK" }.to_json
    ])
    ClaudeSessionRunner.new(@run, runner: fake).call("x")
    assert_equal %w[claude -p --verbose --output-format stream-json --dangerously-skip-permissions --model sonnet --effort high],
                 fake.calls.first[:cmd]
  end

  test "run z resume_session_id dostaje flagę --resume" do
    @run.update!(resume_session_id: "sess-old")
    fake = FakeRunner.new(lines: [
      { type: "result", subtype: "success", session_id: "s2", total_cost_usd: 0.1, duration_ms: 5, result: "OK" }.to_json
    ])
    ClaudeSessionRunner.new(@run, runner: fake).call("x")
    assert_equal %w[claude -p --verbose --output-format stream-json --dangerously-skip-permissions --resume sess-old],
                 fake.calls.first[:cmd]
  end

  test "sesja zapisuje supervisor_pid bieżącego procesu" do
    fake = FakeRunner.new(lines: [
      { type: "result", subtype: "success", session_id: "s", total_cost_usd: 0.1, duration_ms: 5, result: "OK" }.to_json
    ])
    ClaudeSessionRunner.new(@run, runner: fake).call("x")
    assert_equal Process.pid, @run.reload.supervisor_pid
  end

  test "zapisuje zapełnienie kontekstu, rozmiar okna i liczniki cache'u" do
    fake = FakeRunner.new(lines: [
      { type: "assistant", message: { content: [ { type: "text", text: "Czytam" } ],
        usage: { input_tokens: 2, cache_read_input_tokens: 100 } } }.to_json,
      { type: "assistant", message: { content: [ { type: "tool_use", name: "Read" } ],
        usage: { input_tokens: 2, cache_creation_input_tokens: 351, cache_read_input_tokens: 288_782 } } }.to_json,
      { type: "result", subtype: "success", session_id: "s", result: "OK",
        usage: { cache_read_input_tokens: 4_505_269, cache_creation_input_tokens: 273_395 },
        modelUsage: { "claude-opus-5" => { "inputTokens" => 32, "contextWindow" => 1_000_000 } } }.to_json
    ])
    ClaudeSessionRunner.new(@run, runner: fake).call("x")
    @run.reload
    assert_equal(
      { context_tokens: 289_135, context_window: 1_000_000,
        cache_read: 4_505_269, cache_creation: 273_395 },
      { context_tokens: @run.context_tokens, context_window: @run.context_window,
        cache_read: @run.cache_read_tokens, cache_creation: @run.cache_creation_tokens }
    )
  end

  # Wiadomość z samym tool_use ma `text` nil. Gdyby trafiła do last_message,
  # panel postępu skasowałby ostatni komunikat widoczny dla użytkownika.
  test "wiadomość bez tekstu nie zamazuje ostatniego komunikatu" do
    fake = FakeRunner.new(lines: [
      { type: "assistant", message: { content: [ { type: "text", text: "Analizuję diff" } ] } }.to_json,
      { type: "assistant", message: { content: [ { type: "tool_use", name: "Read" } ],
        usage: { input_tokens: 5, cache_read_input_tokens: 995 } } }.to_json,
      { type: "result", subtype: "success", session_id: "s", result: "OK" }.to_json
    ])
    ClaudeSessionRunner.new(@run, runner: fake).call("x")
    @run.reload
    assert_equal({ last_message: "Analizuję diff", context_tokens: 1000 },
                 { last_message: @run.last_message, context_tokens: @run.context_tokens })
  end

  # Okno przychodzi dopiero w evencie `result`. Sesja przerwana przed nim nie
  # może wyzerować tego, co wiadomo z poprzedniego pomiaru tego samego runu.
  test "brak modelUsage w result nie kasuje znanego wcześniej okna" do
    @run.update!(context_window: 1_000_000)
    fake = FakeRunner.new(lines: [
      { type: "result", subtype: "success", session_id: "s", result: "OK", modelUsage: {} }.to_json
    ])
    ClaudeSessionRunner.new(@run, runner: fake).call("x")
    assert_equal 1_000_000, @run.reload.context_window
  end

  test "should let the run override the model and effort from the review" do
    @review.update!(model: "sonnet", effort: "high")
    @run.update!(model: "opus", effort: "max")
    fake = FakeRunner.new(lines: [
      { type: "result", subtype: "success", session_id: "s", total_cost_usd: 0.1, duration_ms: 5, result: "OK" }.to_json
    ])
    ClaudeSessionRunner.new(@run, runner: fake).call("x")
    assert_equal %w[claude -p --verbose --output-format stream-json --dangerously-skip-permissions --model opus --effort max],
                 fake.calls.first[:cmd]
  end
end
