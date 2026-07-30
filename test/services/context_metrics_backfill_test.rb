require "test_helper"

class ContextMetricsBackfillTest < ActiveSupport::TestCase
  setup do
    @review = reviews(:pr_review)
    FileUtils.rm_rf(@review.artifacts_dir)
    FileUtils.mkdir_p(@review.artifacts_dir)
  end

  teardown { FileUtils.rm_rf(@review.artifacts_dir) }

  def write_log(kind, *sessions)
    lines = sessions.flat_map do |session|
      sid = session.fetch(:session_id, "s")
      [
        { type: "system", subtype: "init", session_id: sid }.to_json,
        { type: "assistant", session_id: sid, timestamp: session[:at]&.iso8601,
          message: { content: [ { type: "text", text: "…" } ],
                     usage: { input_tokens: 0, cache_read_input_tokens: session.fetch(:context_tokens) } } }.to_json,
        { type: "result", subtype: "success", session_id: sid, result: "OK",
          usage: { cache_read_input_tokens: 5000, cache_creation_input_tokens: 1000 },
          modelUsage: { "claude-opus-5" => { "inputTokens" => 1, "contextWindow" => session.fetch(:window) } } }.to_json
      ]
    end
    File.write(@review.artifacts_dir.join("#{kind}.log"), lines.join("\n") + "\n")
  end

  def run_for(kind, session_id: "s")
    @review.claude_runs.create!(kind: kind, claude_config: "/c", status: "succeeded", session_id: session_id)
  end

  test "uzupełnia metryki z logu i liczy uzupełnione runy" do
    run = run_for("review")
    write_log("review", { context_tokens: 231_000, window: 1_000_000 })
    assert_equal 1, ContextMetricsBackfill.call(Review.where(id: @review.id))
    run.reload
    assert_equal({ tokens: 231_000, window: 1_000_000, cache_read: 5000, cache_creation: 1000 },
                 { tokens: run.context_tokens, window: run.context_window,
                   cache_read: run.cache_read_tokens, cache_creation: run.cache_creation_tokens })
  end

  # Sesja wznowiona przez --resume zachowuje session_id poprzedniej, więc runów nie da
  # się rozdzielić po nim — granicą jest event `init`.
  test "rozdziela sesje z jednego logu po evencie init, nie po session_id" do
    first = run_for("followup")
    second = run_for("followup")
    write_log("followup", { context_tokens: 100_000, window: 1_000_000 },
                          { context_tokens: 289_135, window: 1_000_000 })
    ContextMetricsBackfill.call(Review.where(id: @review.id))
    assert_equal [ 100_000, 289_135 ], [ first.reload.context_tokens, second.reload.context_tokens ]
  end

  # Log bywa ma więcej segmentów niż runów (skasowany run, restart aplikacji w trakcie).
  # Wtedy jedziemy po czasie: segment należy do runu, który wtedy działał. Segment
  # sprzed pierwszego runu jest osierocony i przepada.
  test "przy niezgodnej liczbie segmentów przypisuje po czasie działania runów" do
    orphan_at = Time.utc(2026, 7, 28, 6, 0)
    first = run_for("followup").tap { |r| r.update!(started_at: Time.utc(2026, 7, 28, 6, 10)) }
    second = run_for("followup").tap { |r| r.update!(started_at: Time.utc(2026, 7, 28, 6, 20)) }
    write_log("followup", { context_tokens: 1000, window: 1_000_000, at: orphan_at },
                          { context_tokens: 2000, window: 1_000_000, at: Time.utc(2026, 7, 28, 6, 11) },
                          { context_tokens: 289_135, window: 1_000_000, at: Time.utc(2026, 7, 28, 6, 21) })
    assert_equal 2, ContextMetricsBackfill.call(Review.where(id: @review.id))
    assert_equal [ 2000, 289_135 ], [ first.reload.context_tokens, second.reload.context_tokens ]
  end

  # Dwa segmenty na jeden run (sesja zerwana i wznowiona w tym samym runie) —
  # obowiązuje ostatni pomiar, nie pierwszy.
  test "gdy na jeden run wypada kilka segmentów, wygrywa najpóźniejszy" do
    only = run_for("followup").tap { |r| r.update!(started_at: Time.utc(2026, 7, 28, 6, 10)) }
    write_log("followup", { context_tokens: 1000, window: 1_000_000, at: Time.utc(2026, 7, 28, 6, 11) },
                          { context_tokens: 2000, window: 1_000_000, at: Time.utc(2026, 7, 28, 6, 12) },
                          { context_tokens: 3000, window: 1_000_000, at: Time.utc(2026, 7, 28, 6, 13) })
    ContextMetricsBackfill.call(Review.where(id: @review.id))
    assert_equal 3000, only.reload.context_tokens
  end

  test "nie nadpisuje metryk już zapisanych przez runner" do
    run = run_for("review")
    run.update!(context_tokens: 999, context_window: 1_000_000)
    write_log("review", { context_tokens: 231_000, window: 1_000_000 })
    ContextMetricsBackfill.call(Review.where(id: @review.id))
    assert_equal 999, run.reload.context_tokens
  end

  test "brak logu nie wywraca backfillu" do
    run_for("review")
    assert_equal 0, ContextMetricsBackfill.call(Review.where(id: @review.id))
  end

  # Drugie przejście nie ma już czego uzupełniać — licznik musi to pokazać,
  # inaczej nie da się odróżnić „uzupełniono" od „przeleciało po wszystkim".
  test "powtórne uruchomienie nie liczy runów, których nie ruszyło" do
    run_for("review")
    write_log("review", { context_tokens: 231_000, window: 1_000_000 })
    ContextMetricsBackfill.call(Review.where(id: @review.id))
    assert_equal 0, ContextMetricsBackfill.call(Review.where(id: @review.id))
  end
end
