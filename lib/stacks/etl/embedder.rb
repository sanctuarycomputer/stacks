module Stacks
  module Etl
    class Embedder
      MODEL = 'mixedbread-ai/mxbai-embed-large-v1'.freeze
      DIMENSIONS = 1024
      QUERY_PREFIX = 'Represent this sentence for searching relevant passages: '.freeze

      # Memoized, quantized ONNX pipeline. Downloads + caches the model on first call.
      def self.pipeline
        @pipeline ||= Informers.pipeline('embedding', MODEL, quantized: true)
      end

      def self.embed(texts, input_type: 'document')
        inputs = Array(texts).map(&:to_s)
        inputs = inputs.map { |t| QUERY_PREFIX + t } if input_type == 'query'
        raw = pipeline.call(inputs)
        vectors = raw.first.is_a?(Array) ? raw : [raw]
        { vectors: vectors }
      end
    end
  end
end
