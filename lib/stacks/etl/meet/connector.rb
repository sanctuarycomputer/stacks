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
          # Resolve a notes doc's transcript at INGEST time (not in the source): the transcript
          # Document is guaranteed present by now — whether ingested in an earlier sweep, or as
          # the transcript half of the SAME combined "Notes by Gemini" file yielded just before
          # this notes record. Inherit its decision verbatim (identical privacy wall).
          if (tid = normalized[:transcript_doc_id])
            tdoc = Document.for_drive_doc(tid).first
            return [tdoc.excluded.to_sym, tdoc.excluded_reason.to_sym] if tdoc
          end
          # 1:1 PRIVACY POLICY (deliberate — do NOT max() with the contacts/Calendar count): the
          # head-count must reflect who was ACTUALLY in the meeting, never who was invited.
          # Invite counts over-count (a no-show on a 1:1 makes it look like a group and the
          # private transcript leaks). Use the actual-attendance signal each source provides —
          # Meet participants (API) or distinct speakers (Drive/combined) — in participant_count,
          # even when 0 ("couldn't confirm a group" -> conservatively excluded). Only when that
          # signal is wholly ABSENT (nil) fall back to the contact count.
          count = normalized[:participant_count] || normalized[:contacts].size
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
