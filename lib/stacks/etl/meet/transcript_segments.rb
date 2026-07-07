module Stacks
  module Etl
    module Meet
      # Speaker-line parsing for Google Meet transcripts, shared by DriveSource (standalone
      # "- Transcript" docs) and GeminiNotesSource (transcript embedded in a combined
      # "Notes by Gemini" doc). Moved verbatim from DriveSource — behavior unchanged.
      module TranscriptSegments
        # A speaker line is "Name: <text>". The FIRST token (NAME_HEAD) must start with an
        # uppercase letter (\p{Lu}) or a caseless-script letter (\p{Lo}, e.g. CJK) — that
        # rejects timestamps ("10:30 …"), spoken sentences ("i think the answer is: yes") AND
        # a leading parenthetical ("(Recording note): …"). Trailing tokens (NAME_TAIL) may add
        # more letter-words or a "(Guest)" parenthetical, but NOT bare numbers, so body lines
        # like "Action 1:" / "Phase 2:" don't parse as speakers (a phantom speaker would
        # inflate the distinct-speaker 1:1 count and leak a private 1:1). Meet's anonymous
        # labels are matched explicitly as "Speaker N" etc.
        NAME_HEAD = /[\p{Lu}\p{Lo}][\p{L}.''-]*/
        NAME_TAIL = /(?:[\p{Lu}\p{Lo}][\p{L}.''-]*|\([^)]*\))/
        ANON_LABEL = /(?:Speaker|Guest|Participant) \d{1,4}/
        SPEAKER_LINE = /\A\s*(#{ANON_LABEL}|#{NAME_HEAD}(?:[ ,&]+#{NAME_TAIL}){0,6}):\s+(\S.*)\z/

        def parse_segments(text)
          text.to_s.each_line.filter_map do |raw|
            if (m = raw.chomp.match(SPEAKER_LINE))
              { speaker_name: m[1].strip, speaker_email: nil, text: m[2].strip, started_at: nil, ended_at: nil }
            end
            # Lines without a name-shaped "Name:" prefix — system/footer notes like
            # "Recording stopped" or "X left the call" — are dropped rather than misattributed.
          end
        end

        # Distinct speakers heard — the actual-attendance head-count for the 1:1 privacy
        # classifier. parse_segments never yields a nil speaker_name.
        def distinct_speaker_count(segments)
          segments.map { |s| s[:speaker_name] }.uniq.size
        end
      end
    end
  end
end
