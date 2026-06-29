module Stacks
  module Etl
    # Indexes (chunks + embeds + resolves speakers for) a corpus-eligible document
    # from its STORED transcript segments — no Google re-fetch. This is what makes
    # exclusion reversible: an excluded meeting keeps its full Meeting + segments, so
    # flipping it to `manually_included` can index it at any time, even long after the
    # meeting has aged out of Google's API/Drive retention.
    class Reindexer
      # Returns true if it indexed, false if there was nothing to index.
      def self.call(document)
        return false unless document.corpus_eligible?
        meeting = document.source_record
        return false unless meeting.is_a?(Meeting)

        segments = meeting.segments.order(:position).map do |s|
          { speaker_name: s.speaker_name, speaker_email: s.speaker_email, text: s.text,
            started_at: s.started_at, ended_at: s.ended_at, start_offset: nil, end_offset: nil }
        end
        return false if segments.empty?

        ActiveRecord::Base.transaction { Connector.index_chunks!(document, segments) }
        document.chunks.exists?
      end
    end
  end
end
