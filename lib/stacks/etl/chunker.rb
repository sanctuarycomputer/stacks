module Stacks
  module Etl
    class Chunker
      MAX_WORDS = 380      # ~512 tokens
      OVERLAP_WORDS = 40

      def self.call(segments:)
        chunks = []
        coalesce(Array(segments)).each do |seg|
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

      # Merge consecutive segments from the SAME speaker into one turn before chunking.
      # The Meet REST API emits one segment per short utterance, so without this a monologue
      # becomes dozens of tiny 3-10 word chunks that embed poorly; coalescing yields
      # paragraph-sized chunks matching the Drive path. Speaker changes still break the turn,
      # so each chunk keeps a single-speaker attribution.
      def self.coalesce(segments)
        segments.each_with_object([]) do |seg, out|
          text = seg[:text].to_s.strip
          next if text.empty?
          last = out.last
          if last && last[:speaker_name] == seg[:speaker_name] && last[:speaker_email] == seg[:speaker_email]
            last[:text] = "#{last[:text]} #{text}".strip
          else
            # Keep the first turn's started_at as the merged turn's occurred_at; the chunker
            # only consumes started_at, so end times are intentionally not tracked here.
            out << seg.merge(text: text)
          end
        end
      end

      def self.slices(words)
        # A single chunk up to MAX+OVERLAP avoids splitting a slightly-over-MAX segment
        # into two windows that are ~all overlap (a near-duplicate tail chunk).
        return [words] if words.size <= MAX_WORDS + OVERLAP_WORDS
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
