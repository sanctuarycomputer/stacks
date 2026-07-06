module Stacks
  module Etl
    class Embedder
      MODEL = 'mixedbread-ai/mxbai-embed-large-v1'.freeze
      DIMENSIONS = 1024
      QUERY_PREFIX = 'Represent this sentence for searching relevant passages: '.freeze

      PIPELINE_MUTEX = Mutex.new

      # Memoized, quantized ONNX pipeline. Downloads + caches the model on first call
      # and spins up the ONNX runtime session — a multi-second cold start. Guarded by
      # a mutex so a warmup thread and a concurrent first request can't each pay (or
      # race) that build; whichever arrives first builds it, the rest reuse it.
      def self.pipeline
        return @pipeline if @pipeline
        PIPELINE_MUTEX.synchronize { @pipeline ||= Informers.pipeline('embedding', MODEL, quantized: true) }
      end

      # Drop the memoized pipeline. Native ONNX sessions don't survive `fork`, so a
      # preload+cluster web server must reset in each worker before rebuilding.
      def self.reset!
        PIPELINE_MUTEX.synchronize { @pipeline = nil }
      end

      # Force the cold start (model load + ONNX session init + first inference) ahead
      # of real traffic, so the FIRST semantic/hybrid search isn't the one that pays it
      # and times out. Safe to call from a boot-time background thread: any failure is
      # logged and swallowed rather than taking down the worker.
      def self.warm!
        embed(['warmup'], input_type: 'query')
        true
      rescue => e
        Rails.logger.warn("[Stacks::Etl::Embedder] pipeline warmup failed: #{e.class}: #{e.message}")
        false
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
