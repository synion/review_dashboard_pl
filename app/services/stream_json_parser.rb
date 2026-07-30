# Parser linii z `claude -p --output-format stream-json --verbose`.
class StreamJsonParser
  Event = Struct.new(:type, :session_id, :text, :cost_usd, :duration_ms, :at,
                     :context_tokens, :context_window, :cache_read_tokens, :cache_creation_tokens,
                     keyword_init: true)

  def self.parse_line(line)
    data = JSON.parse(line)
    case data["type"]
    when "system"
      Event.new(type: :init, session_id: data["session_id"]) if data["subtype"] == "init"
    when "assistant"
      text = Array(data.dig("message", "content"))
        .select { |c| c["type"] == "text" }
        .map { |c| c["text"] }
        .join("\n")
      context = context_tokens(data.dig("message", "usage"))
      # Wiadomość z samym tool_use nie ma tekstu, ale niesie największy przyrost
      # kontekstu w sesji, która głównie czyta pliki — nie wolno jej zgubić.
      if text.present? || context
        Event.new(type: :assistant_text, text: text.presence, context_tokens: context, at: parse_time(data["timestamp"]))
      end
    when "result"
      usage = data["usage"]
      Event.new(type: :result, session_id: data["session_id"], text: data["result"],
                cost_usd: data["total_cost_usd"], duration_ms: data["duration_ms"],
                context_window: context_window(data["modelUsage"]),
                cache_read_tokens: usage&.dig("cache_read_input_tokens"),
                cache_creation_tokens: usage&.dig("cache_creation_input_tokens"))
    end
  rescue JSON::ParserError
    nil
  end

  # Znacznik czasu niesie tylko część linii (event `init` już nie), a backfill po nim
  # przypisuje segmenty logu do runów. Zepsuta data ma być brakiem daty, nie wyjątkiem
  # w środku przetwarzania miliona linii.
  def self.parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  # Zapełnienie okna po tej wiadomości: wszystko, co model przeczytał na wejściu,
  # niezależnie od tego, czy z cache'u, czy świeżo. Świadomie NIE suma po sesji —
  # ta (z eventu `result`) bywa kilkanaście razy większa od realnego kontekstu.
  def self.context_tokens(usage)
    return if usage.blank?

    tokens = usage.values_at("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens").sum(&:to_i)
    tokens if tokens.positive?
  end

  # modelUsage bywa wielowpisowe (subagent na innym modelu). Bierzemy wpis o największym
  # zużyciu — model sesji głównej dominuje o rzędy wielkości, a reguła jest bezstanowa:
  # parser nie musi pamiętać, jaki model widział w poprzednim evencie.
  def self.context_window(model_usage)
    return if model_usage.blank?

    main = model_usage.values.max_by do |usage|
      usage.values_at("inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens").sum(&:to_i)
    end
    main["contextWindow"]
  end

  private_class_method :parse_time, :context_tokens, :context_window
end
