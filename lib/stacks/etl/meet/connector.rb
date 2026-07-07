module Stacks
  module Etl
    module Meet
      class Connector < Stacks::Etl::Connector
        def initialize(admin_email:, mode: :api, since: nil, until_time: nil, parse_transcript: false)
          @admin_email = admin_email
          @mode = mode
          @since = since
          @until_time = until_time
          @parse_transcript = parse_transcript
        end

        def source = :meet

        def extract(since:)
          src = source_object(since || @since)
          # Lazy: pull + ingest one meeting at a time rather than materializing the whole
          # org's transcripts (memory) before any are stored.
          Enumerator.new { |y| src.each_meeting { |n| y << n } }
        end

        def exclusion_for(normalized)
          if (tid = normalized[:transcript_doc_id])
            tdoc = Document.for_drive_doc(tid).first
            return [tdoc.excluded.to_sym, tdoc.excluded_reason.to_sym] if tdoc
            # Transcript referenced but not ingested yet -> fall through and classify on the
            # invited count below (a >2-invited meeting is never a 1:1; a <=2 invited stays a
            # 1:1). Once the transcript's Document lands, apply_exclusion re-inherits its exact
            # decision. No conservative hold is needed: the invited count is already the 1:1
            # signal, and the notes carry their own invited list.
          end
          # 1:1 POLICY: privacy is defined by the INTENDED AUDIENCE (the invite count), NOT by
          # who actually showed up. A meeting invited to more than 2 people is not a private
          # 1:1, regardless of attendance — so take the LARGER of actual attendance
          # (participant_count) and the invited/contact count. When the invite count is unknown
          # (empty contacts) this falls back to actual attendance; when BOTH are absent (max is
          # 0) it is conservatively treated as a possible 1:1. Title rules (perf/comp/HR/etc.)
          # still wall off sensitively-named meetings regardless of size.
          count = [normalized[:participant_count].to_i, normalized[:contacts].size].max
          Classifier.call(title: normalized[:title], participant_count: count)
        end

        private

        def source_object(since)
          case @mode
          when :drive        then DriveSource.new(@admin_email, since: since || 90.days.ago, until_time: @until_time)
          when :gemini_notes then GeminiNotesSource.new(@admin_email, since: since || 90.days.ago, until_time: @until_time, parse_transcript: @parse_transcript)
          else MeetApiSource.new(@admin_email, since: since)
          end
        end
      end
    end
  end
end
