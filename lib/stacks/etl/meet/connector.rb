module Stacks
  module Etl
    module Meet
      class Connector < Stacks::Etl::Connector
        def initialize(admin_email:, mode: :api, since: nil, until_time: nil)
          @admin_email = admin_email
          @mode = mode
          @since = since
          @until_time = until_time
        end

        def source = :meet

        def extract(since:)
          src = source_object(since || @since)
          # Lazy: pull + ingest one meeting at a time rather than materializing the whole
          # org's transcripts (memory) before any are stored.
          Enumerator.new { |y| src.each_meeting { |n| y << n } }
        end

        def exclusion_for(normalized)
          # Use the meeting's real participant_count (not contacts.size, which may be the
          # Calendar attendee list or a speaker-name fallback) so a big meeting where few
          # people spoke isn't mis-flagged as a 1:1.
          count = normalized[:participant_count] || normalized[:contacts].size
          Classifier.call(title: normalized[:title], participant_count: count)
        end

        private

        def source_object(since)
          if @mode == :drive
            DriveSource.new(@admin_email, since: since || 90.days.ago, until_time: @until_time)
          else
            MeetApiSource.new(@admin_email, since: since)
          end
        end
      end
    end
  end
end
