require 'digest'

module Stacks
  module Etl
    module Meet
      class DriveSource
        QUERY = "mimeType='application/vnd.google-apps.document' and name contains 'Transcript'".freeze

        def initialize(user_email, since:, until_time: nil)
          @user_email = user_email
          @since = coerce(since)
          # Upper bound on createdTime — lets the backfill cover only the OLDER window the
          # Meet API can't reach, so Drive and the ongoing API sweep never ingest the same
          # meeting (partitioned dedup, no fragile cross-source merge).
          @until_time = coerce(until_time)
          @service = Auth.drive_service(sub: user_email)
          @enricher = CalendarEnricher.new(user_email)
        end

        def each_meeting
          page = nil
          loop do
            q = "#{QUERY} and createdTime > '#{@since.utc.iso8601}'"
            q += " and createdTime < '#{@until_time.utc.iso8601}'" if @until_time
            resp = @service.list_files(q: q, fields: 'nextPageToken, files(id,name,createdTime)', page_token: page)
            Array(resp.files).each do |f|
              n = normalize(f)
              yield n if n
            end
            page = resp.next_page_token
            break unless page
          end
        end

        private

        def normalize(file)
          # Reverse side of the Drive/API dedup: if the ongoing Meet API sync already
          # ingested this exact transcript, defer to that Document instead of creating a
          # second one keyed on file.id. Exclude THIS Drive doc (external_id == file.id) from
          # the check — otherwise a re-scan would match the row the Drive sync itself created
          # last run and skip re-ingesting a corrected/finalized or re-included transcript.
          return nil if Document.for_drive_doc(file.id).where.not(external_id: file.id).exists?
          text = @service.export_file(file.id, 'text/plain')
          # Drive transcripts have no per-line timestamps; stamp every segment with the
          # doc's created time so chunks get a real occurred_at (date-scoped search needs it).
          segments = parse_segments(text).each { |s| s[:started_at] = file.created_time }
          title = clean_title(file.name)
          # Drive transcripts have no Meet code, so enrich by matching a Calendar event
          # with the SAME title near the doc's time (best-effort) for attendee emails.
          enrichment = @enricher.enrich(started_at: file.created_time, meeting_code: nil,
                                        fallback_title: title, title_hint: title)
          attendees = enrichment[:attendees]
          contacts =
            if attendees.any?
              attendees.map { |a| { email: a[:email], name: a[:name], role: 'attendee' } }
            else
              segments.map { |s| { email: nil, name: s[:speaker_name], role: 'speaker' } }.uniq
            end
          speaker_count = distinct_speaker_count(segments)
          {
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: file.created_time,
            content_hash: Digest::SHA256.hexdigest(text.to_s),
            # Head-count for the 1:1 privacy classifier = distinct speakers actually heard.
            # Drive has no actual-attendance list, and the Calendar invite count over-counts
            # no-shows (which would let a 1:1 leak), so we deliberately use speakers, NOT
            # attendees, here — see Connector#exclusion_for. (Calendar attendees are still
            # used for contact/email attribution below, just not for the head-count.)
            participant_count: speaker_count,
            contacts: contacts,
            segments: segments,
            raw_metadata: { 'drive_doc_id' => file.id },
            build_source_record: ->(doc) { build_meeting(doc, file, segments, title, speaker_count, enrichment[:organizer_email]) }
          }
        end

        def coerce(t)
          return nil if t.nil?
          t.is_a?(String) ? Time.parse(t) : t
        end

        # Distinct speakers heard in the transcript — the actual-attendance head-count for
        # the 1:1 privacy classifier. parse_segments never yields a nil speaker_name.
        def distinct_speaker_count(segments)
          segments.map { |s| s[:speaker_name] }.uniq.size
        end

        # Meet names transcript docs like "Title - Transcript" or
        # "Title (2026/06/27 17:00 GMT-7) - Transcript". Strip the "- Transcript" suffix and
        # ONLY a trailing parenthetical that is actually Meet's date stamp — which always
        # carries a date (Y/M/D) AND/OR a "GMT" marker. We deliberately do NOT match a bare
        # clock time, so a real title like "Retro (5:00 format)", "Roadmap (Q3 2026)" or
        # "Planning (3 items)" survives — the cleaned title is the key the Drive Calendar
        # enricher matches on.
        DATE_STAMP = %r{\s*\((?:\d{2,4}[/-]\d{1,2}[/-]\d{1,2}|[^)]*\bGMT\b)[^)]*\)\s*\z}
        def clean_title(name)
          name.to_s
              .sub(/\s*-\s*Transcript\s*\z/i, '')
              .sub(DATE_STAMP, '')
              .strip
              .presence || name.to_s
        end

        # A speaker line is "Name: <text>". The name must LOOK like a name. The FIRST token
        # (NAME_HEAD) must start with an uppercase letter (\p{Lu}) or a caseless-script
        # letter (\p{Lo}, e.g. CJK) — that rejects timestamps ("10:30 …", leading digit),
        # spoken sentences ("i think the answer is: yes", leading lowercase) AND a leading
        # parenthetical ("(Recording note): …", which must not be a phantom speaker).
        # Trailing tokens (NAME_TAIL) may add more letter-words or a "(Guest)" parenthetical,
        # but NOT bare numbers, so body lines like "Action 1:" / "Phase 2:" don't parse as
        # speakers (a phantom speaker would inflate the distinct-speaker 1:1 count and leak a
        # private 1:1). Meet's anonymous labels are matched explicitly as "Speaker N" etc.
        NAME_HEAD = /[\p{Lu}\p{Lo}][\p{L}.'’-]*/
        NAME_TAIL = /(?:[\p{Lu}\p{Lo}][\p{L}.'’-]*|\([^)]*\))/
        ANON_LABEL = /(?:Speaker|Guest|Participant) \d{1,4}/
        SPEAKER_LINE = /\A\s*(#{ANON_LABEL}|#{NAME_HEAD}(?:[ ,&]+#{NAME_TAIL}){0,6}):\s+(\S.*)\z/

        def parse_segments(text)
          text.to_s.each_line.filter_map do |raw|
            if (m = raw.chomp.match(SPEAKER_LINE))
              { speaker_name: m[1].strip, speaker_email: nil, text: m[2].strip, started_at: nil, ended_at: nil }
            end
            # Lines without a name-shaped "Name:" prefix — system/footer notes like
            # "Recording stopped" or "X left the call" — are dropped. Google Docs exports
            # each speaker turn as one paragraph/line, so these are not wrapped continuations;
            # appending them to the previous speaker would MISATTRIBUTE that text to a real
            # person in search, which is worse for the corpus than omitting it.
          end
        end

        def build_meeting(doc, file, segments, title, speaker_count, organizer_email)
          meeting = Meeting.find_or_initialize_by(drive_transcript_doc_id: file.id)
          meeting.update!(meet_source: :drive, title: title, started_at: file.created_time,
                          participant_count: speaker_count,
                          organizer_email: organizer_email,
                          raw_metadata: { 'document_id' => doc.id })
          meeting.segments.destroy_all
          segments.each_with_index do |s, i|
            # Persist started_at so the Reindexer (which reads STORED segments) yields chunks
            # with a real occurred_at, matching live ingest.
            meeting.segments.create!(position: i, speaker_name: s[:speaker_name], text: s[:text],
                                     started_at: s[:started_at])
          end
          meeting
        end
      end
    end
  end
end
