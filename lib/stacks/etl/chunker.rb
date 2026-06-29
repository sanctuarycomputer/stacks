module Stacks
  module Etl
    class Chunker
      MAX_WORDS = 380      # ~512 tokens
      OVERLAP_WORDS = 40

      def self.call(segments:)
        chunks = []
        segments.each do |seg|
          words = seg[:text].to_s.split
          next if words.empty?
          slices(words).each do |slice|
            chunks << {
              content: slice.join(' '),
              start_offset: nil,
              end_offset: nil,
              speaker_name: seg[:speaker_name],
              speaker_email: seg[:speaker_email],
              occurred_at: seg[:started_at]
            }
          end
        end
        chunks.each_with_index { |c, i| c[:start_offset] = i }
        chunks
      end

      def self.slices(words)
        return [words] if words.size <= MAX_WORDS
        out = []
        i = 0
        loop do
          out << words[i, MAX_WORDS]
          # Stop once a slice reaches the end; otherwise the next window would be almost
          # entirely overlap — a near-duplicate chunk.
          break if i + MAX_WORDS >= words.size
          i += MAX_WORDS - OVERLAP_WORDS
        end
        out
      end
    end
  end
end
