module Stacks
  module Etl
    module Meet
      # Shared notes-parsing helpers for Google Meet "Notes by Gemini" docs, included
      # by both GeminiNotesSource (Drive scan) and MeetApiSource (docsDestination export).
      # Owns the split point, the invited-email extractor, and the notes-body segmenter.
      module NotesDoc
        # First markdown heading whose text contains "Transcript" — tolerant of the 📖
        # emoji so a future Google change doesn't break it. The inline "Meeting records
        # [Transcript](…)" link is NOT a heading and is not matched.
        TRANSCRIPT_HEADING = /^\#{1,2}\s+.*Transcript.*$/i

        # Split a combined doc into [notes_body_markdown, transcript_markdown]. Everything
        # from the transcript heading onward is the transcript; everything before is the
        # notes body. Returns transcript_md = "" when no transcript heading is present.
        def split_transcript(text)
          s = text.to_s
          if (m = s.match(TRANSCRIPT_HEADING))
            [s[0...m.begin(0)], s[m.begin(0)..]]
          else
            [s, ""]
          end
        end

        # Emails only appear as mailto: links, primarily in the "Invited" block.
        def invited_emails_from(text)
          text.to_s.scan(/mailto:([^)\s]+)/).flatten.map { |e| e.downcase }
              .reject { |e| e.end_with?("resource.calendar.google.com") }.uniq
        end

        # Convert the notes portion (already split from the transcript) into paragraph
        # segments for the chunker. Strips trailing Gemini feedback/footer noise.
        # speaker_name is nil — notes are unattributed prose, not transcribed speech.
        def notes_segments(markdown, occurred_at:)
          cleaned = markdown.to_s
                            .gsub(/We['']ve updated the Decisions section.*\z/m, "")
                            .gsub(/Let us know what you think.*\z/m, "")
                            .gsub(/You should review Gemini['']s notes.*\z/m, "")
          cleaned.split(/\n{2,}/).map(&:strip).reject(&:empty?).map do |para|
            { speaker_name: nil, speaker_email: nil, text: para, started_at: occurred_at, ended_at: nil }
          end
        end
      end
    end
  end
end
