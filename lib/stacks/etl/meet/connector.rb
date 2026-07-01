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
          return normalized[:inherit_exclusion] if normalized[:inherit_exclusion]
          # 1:1 PRIVACY POLICY (deliberate — do NOT "improve" this to max() with the
          # contacts/Calendar count): the head-count must reflect who was ACTUALLY in the
          # meeting, never who was invited. Invite counts over-count (a no-show on a 1:1
          # makes it look like 3 people and the private transcript leaks). So we use the
          # actual-attendance signal each source provides — Meet participants (API) or
          # distinct speakers (Drive) — in participant_count, even when it's 0 ("couldn't
          # confirm a group" -> conservatively excluded). Only when that signal is wholly
          # ABSENT (nil) do we fall back to the contact count. Under-counting at worst
          # over-excludes a quiet group meeting (recoverable); over-counting would leak.
          count = normalized[:participant_count] || normalized[:contacts].size
          Classifier.call(title: normalized[:title], participant_count: count)
        end

        private

        def source_object(since)
          case @mode
          when :drive        then DriveSource.new(@admin_email, since: since || 90.days.ago, until_time: @until_time)
          when :gemini_notes then GeminiNotesSource.new(@admin_email, since: since || 90.days.ago, until_time: @until_time)
          else MeetApiSource.new(@admin_email, since: since)
          end
        end
      end
    end
  end
end
