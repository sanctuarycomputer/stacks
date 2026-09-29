# Provider-agnostic facade for direct LLM calls from Stacks. Call sites depend
# ONLY on this module — swapping providers means writing one adapter class
# under Stacks::AI::Providers and flipping config[:ai][:provider].
module Stacks
  module AI
    class Error < StandardError; end

    # data: validated Hash conforming to the requested schema.
    Result = Struct.new(:data, :input_tokens, :output_tokens)

    PROVIDERS = { "anthropic" => "Stacks::AI::Providers::Anthropic" }.freeze

    class << self
      # tier: :fast (cheap classification) — :smart reserved, unmapped for now.
      # max_tokens: nil keeps the provider's default output cap.
      def extract(system:, prompt:, schema:, tier: :fast, max_tokens: nil)
        opts = { system: system, prompt: prompt, schema: schema, tier: tier }
        opts[:max_tokens] = max_tokens if max_tokens
        provider.extract(**opts)
      end

      # The provider model a tier maps to, so a stored result can say which model made it.
      def model_for(tier = :fast)
        provider.model_for(tier)
      end

      def configured?
        provider.configured?
      end

      def provider
        name = Stacks::Utils.config.dig(:ai, :provider).presence || "anthropic"
        klass = PROVIDERS[name.to_s] or raise Error, "Unknown AI provider: #{name}"
        klass.constantize
      end
    end
  end
end
