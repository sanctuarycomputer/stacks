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

        INPUTS_KEY = 'privacy_inputs'.freeze
        # Real attendance of a notes-only meeting, from the Meet API (MeetApiSource). Kept across
        # re-ingests: the Drive notes sync re-reads the same file later and doesn't know it.
        ATTENDANCE_KEY = 'meet_attendance'.freeze

        def preserved_metadata_keys = super + [ATTENDANCE_KEY]

        # One notes Doc can be the destination of more than one conference record (a call that
        # was ended and restarted). Their attendance counts must not overwrite each other; keep
        # the SMALLER one, since fewer people means more gets walled off.
        def merge_metadata(kept, incoming)
          merged = super
          old, new = kept[ATTENDANCE_KEY], incoming[ATTENDANCE_KEY]
          if old && new && old['conference_record'] != new['conference_record']
            merged[ATTENDANCE_KEY] = [old, new].min_by { |a| a['participants'].to_i }
          end
          merged
        end

        # The privacy wall for meetings: the deterministic rules first, then — for whatever they
        # let through (a 3+ person meeting with an innocuous title) — the LLM content review of
        # the document's OWN text. Notes are reviewed too: notes and transcription are separate
        # switches in Meet, so notes can cover a part of the meeting the transcript never saw.
        def exclusion_for(normalized, doc = nil)
          decision = deterministic_exclusion(normalized, doc)
          return decision unless decision == [:not_excluded, :none]
          Stacks::Etl::ContentReview.call(doc: doc, text: Stacks::Etl::ContentReview.text_of(normalized[:segments]),
                                          content_hash: normalized[:content_hash] || doc&.content_hash)
        end

        # Rules only (no model call). Public so the Reclassifier's dry run can preview it.
        def deterministic_exclusion(normalized, doc = nil)
          return notes_exclusion(normalized, doc) if notes?(normalized)

          # 1:1 POLICY (transcripts): privacy is defined by the INTENDED AUDIENCE (the invite
          # count), not only by who showed up — take the LARGER of actual attendance and the
          # invited count. When both are absent (max is 0) it is conservatively a possible 1:1.
          # A 3+-invited meeting where only 2 turned up is backstopped by the content review.
          participants = normalized[:participant_count].to_i
          invited = normalized.key?(:invite_count) ? normalized[:invite_count].to_i : Array(normalized[:contacts]).size
          # Record the head-counts we decided on, so the nightly Reclassifier (which works from
          # stored rows) reaches the SAME decision instead of flapping the doc every night.
          if doc
            doc.raw_metadata = (doc.raw_metadata || {}).merge(
              INPUTS_KEY => { 'participant_count' => participants, 'invite_count' => invited }
            )
          end
          Stacks::Etl::Classifier.call(title: normalized[:title], participant_count: [participants, invited].max)
        end

        private

        def notes?(normalized) = normalized[:source].to_s == 'gemini_notes'

        # G2: notes are classified by their transcript, because only the transcript knows who
        # actually attended. With no transcript, a notes-only meeting seen by the Meet API is
        # classified on its REAL attendance; otherwise attendance is unknown -> default-deny (a
        # human can include it; it re-inherits once a transcript is ingested). The notes' own title
        # is checked first: an API transcript's title can fall back to the Meet code.
        def notes_exclusion(normalized, doc = nil)
          titled = Stacks::Etl::Classifier.title_exclusion(normalized[:title])
          return titled if titled
          tid = normalized[:transcript_doc_id]
          transcripts = tid.present? ? Document.for_drive_doc(tid).to_a : []
          return inherited_from(transcripts) if transcripts.any?
          attended = attendance(normalized, doc)
          return Stacks::Etl::Classifier.call(title: normalized[:title], participant_count: attended) if attended
          [:auto_excluded, :attendance_unknown]
        end

        def attendance(normalized, doc)
          meta = normalized.dig(:raw_metadata, ATTENDANCE_KEY) || doc&.raw_metadata&.dig(ATTENDANCE_KEY)
          meta && meta['participants'].to_i
        end

        # Strictest transcript wins (the Drive + API rows of one meeting could disagree). Human
        # states are mapped to automatic ones: copying `manually_included` would human-LOCK the
        # notes, so a later human exclusion of the transcript would never reach them.
        def inherited_from(transcripts)
          walled = transcripts.find { |t| !t.corpus_eligible? }
          return [:not_excluded, :none] unless walled
          [:auto_excluded, walled.manually_excluded? ? :manual : walled.excluded_reason.to_sym]
        end


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
