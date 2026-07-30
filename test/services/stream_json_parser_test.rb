require "test_helper"

class StreamJsonParserTest < ActiveSupport::TestCase
  test "init niesie session_id" do
    line = { type: "system", subtype: "init", session_id: "sess-1" }.to_json
    event = StreamJsonParser.parse_line(line)
    assert_equal({ type: :init, session_id: "sess-1" }, { type: event.type, session_id: event.session_id })
  end

  test "assistant skleja bloki tekstowe" do
    line = { type: "assistant", message: { content: [
      { type: "text", text: "Sprawdzam model" }, { type: "tool_use", name: "Read" }, { type: "text", text: "Invoice" }
    ] } }.to_json
    event = StreamJsonParser.parse_line(line)
    assert_equal({ type: :assistant_text, text: "Sprawdzam model\nInvoice" }, { type: event.type, text: event.text })
  end

  test "assistant bez tekstu daje nil" do
    line = { type: "assistant", message: { content: [ { type: "tool_use", name: "Bash" } ] } }.to_json
    assert_nil StreamJsonParser.parse_line(line)
  end

  test "result niesie koszt, czas i tekst końcowy" do
    line = { type: "result", subtype: "success", session_id: "sess-1", total_cost_usd: 0.42, duration_ms: 61_000, result: "Gotowe" }.to_json
    event = StreamJsonParser.parse_line(line)
    assert_equal(
      { type: :result, session_id: "sess-1", cost_usd: 0.42, duration_ms: 61_000, text: "Gotowe" },
      { type: event.type, session_id: event.session_id, cost_usd: event.cost_usd, duration_ms: event.duration_ms, text: event.text }
    )
  end

  # Sedno zmiany: wiadomość z samym tool_use nie ma tekstu, ale to ona niesie
  # największy przyrost kontekstu w sesji, która głównie czyta pliki.
  test "assistant bez tekstu, ale z usage, niesie zapełnienie kontekstu" do
    line = { type: "assistant", message: { content: [ { type: "tool_use", name: "Read" } ],
      usage: { input_tokens: 2, cache_creation_input_tokens: 351, cache_read_input_tokens: 288_782 } } }.to_json
    event = StreamJsonParser.parse_line(line)
    assert_equal({ type: :assistant_text, text: nil, context_tokens: 289_135 },
                 { type: event.type, text: event.text, context_tokens: event.context_tokens })
  end

  test "assistant z tekstem i usage niesie jedno i drugie" do
    line = { type: "assistant", message: { content: [ { type: "text", text: "Czytam" } ],
      usage: { input_tokens: 10, cache_read_input_tokens: 90 } } }.to_json
    event = StreamJsonParser.parse_line(line)
    assert_equal({ text: "Czytam", context_tokens: 100 }, { text: event.text, context_tokens: event.context_tokens })
  end

  # Zerowe usage (wiadomość syntetyczna, np. odpowiedź na /compact) to nie pomiar.
  test "assistant z zerowym usage nie udaje pomiaru" do
    line = { type: "assistant", message: { content: [ { type: "text", text: "Not enough messages to compact." } ],
      usage: { input_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } }.to_json
    assert_nil StreamJsonParser.parse_line(line).context_tokens
  end

  test "result niesie rozmiar okna i liczniki cache'u" do
    line = { type: "result", subtype: "success", session_id: "sess-1", result: "Gotowe",
             usage: { cache_read_input_tokens: 4_505_269, cache_creation_input_tokens: 273_395 },
             modelUsage: { "claude-opus-5" => { "inputTokens" => 32, "cacheReadInputTokens" => 4_505_269,
                                                "cacheCreationInputTokens" => 273_395, "contextWindow" => 1_000_000 } } }.to_json
    event = StreamJsonParser.parse_line(line)
    assert_equal({ window: 1_000_000, cache_read: 4_505_269, cache_creation: 273_395 },
                 { window: event.context_window, cache_read: event.cache_read_tokens,
                   cache_creation: event.cache_creation_tokens })
  end

  # Subagent na innym modelu dokłada drugi wpis. Okno sesji głównej to ten
  # z największym zużyciem, a nie pierwszy z brzegu.
  test "przy wielu modelach wygrywa okno modelu o największym zużyciu" do
    line = { type: "result", subtype: "success", result: "x", modelUsage: {
      "claude-haiku-4-5" => { "inputTokens" => 10, "cacheReadInputTokens" => 500, "contextWindow" => 200_000 },
      "claude-opus-5" => { "inputTokens" => 20, "cacheReadInputTokens" => 300_000, "contextWindow" => 1_000_000 }
    } }.to_json
    assert_equal 1_000_000, StreamJsonParser.parse_line(line).context_window
  end

  test "result bez modelUsage i bez usage nie zmyśla liczb" do
    line = { type: "result", subtype: "success", result: "x", modelUsage: {} }.to_json
    event = StreamJsonParser.parse_line(line)
    assert_nil event.context_window
    assert_nil event.cache_read_tokens
  end

  test "śmieciowa linia daje nil" do
    assert_nil StreamJsonParser.parse_line("not json")
    assert_nil StreamJsonParser.parse_line({ type: "unknown" }.to_json)
  end
end
