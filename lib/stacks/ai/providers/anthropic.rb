class Stacks::AI::Providers::Anthropic
  include HTTParty
  base_uri "https://api.anthropic.com/v1"

  # Abstract tiers — call sites never name provider models.
  TIER_MODELS = { fast: "claude-haiku-4-5" }.freeze
  MAX_TOKENS = 512
  RETRYABLE_CODES = [429, 500, 529].freeze
  MAX_ATTEMPTS = 3

  class << self
    def configured?
      api_key.present?
    end

    def extract(system:, prompt:, schema:, tier:)
      model = TIER_MODELS.fetch(tier) { raise ArgumentError, "Unknown Stacks::AI tier: #{tier}" }
      raise Stacks::AI::Error, "Anthropic API key not configured" unless configured?

      response = post_with_retries(
        model: model,
        max_tokens: MAX_TOKENS,
        system: system,
        messages: [{ role: "user", content: prompt }],
        # Native structured outputs — the deprecated top-level `output_format`
        # param must not be used.
        output_config: { format: { type: "json_schema", schema: schema } }
      )

      parsed = response.parsed_response
      raise Stacks::AI::Error, "Response truncated (stop_reason=max_tokens)" if parsed["stop_reason"] == "max_tokens"

      text = parsed.dig("content", 0, "text")
      data = begin
        JSON.parse(text.to_s)
      rescue JSON::ParserError => e
        raise Stacks::AI::Error, "Unparseable structured output: #{e.message}"
      end
      validate!(data, schema)

      usage = parsed["usage"] || {}
      Stacks::AI::Result.new(data, usage["input_tokens"].to_i, usage["output_tokens"].to_i)
    end

    private

    def post_with_retries(body)
      attempts = 0
      loop do
        attempts += 1
        response = post("/messages", headers: headers, body: body.to_json)
        code = response.code.to_i
        return response if code == 200

        if RETRYABLE_CODES.include?(code) && attempts < MAX_ATTEMPTS
          sleep((response.headers["retry-after"] || 2**attempts).to_i)
          next
        end
        message = response.parsed_response.is_a?(Hash) ? response.parsed_response.dig("error", "message") : nil
        raise Stacks::AI::Error, "Anthropic API error #{code}: #{message || "unknown"}"
      end
    end

    # Shallow safety net over the API-side schema enforcement.
    def validate!(data, schema)
      raise Stacks::AI::Error, "Structured output is not an object" unless data.is_a?(Hash)
      missing = Array(schema["required"]) - data.keys
      raise Stacks::AI::Error, "Structured output missing keys: #{missing.join(", ")}" if missing.any?
    end

    def headers
      {
        "x-api-key" => api_key,
        "anthropic-version" => "2023-06-01",
        "content-type" => "application/json"
      }
    end

    def api_key
      Stacks::Utils.config.dig(:anthropic, :api_key)
    end
  end
end
