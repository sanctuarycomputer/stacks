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
          # ingested this exact transcript (it records the Drive doc id in raw_metadata),
          # defer to that Document instead of creating a second one keyed on file.id. This
          # is the common ordering — the API sweep runs continuously, so for meetings in the
          # Drive/API overlap window the API Document usually exists first.
          return nil if Document.where(source: :meet)
                                .where("raw_metadata->>'drive_doc_id' = ?", file.id).exists?
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
          {
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: file.created_time,
            content_hash: Digest::SHA256.hexdigest(text.to_s),
            # Prefer the Calendar attendee count (accurate) for the 1:1 classifier; the
            # distinct-speaker count is only a fallback and would mis-flag a big meeting
            # where few people spoke as a 1:1.
            participant_count: attendees.any? ? attendees.size : segments.map { |s| s[:speaker_name] }.compact.uniq.size,
            contacts: contacts,
            segments: segments,
            raw_metadata: { 'drive_doc_id' => file.id },
            build_source_record: ->(doc) { build_meeting(doc, file, segments, title) }
          }
        end

        def coerce(t)
          return nil if t.nil?
          t.is_a?(String) ? Time.parse(t) : t
        end

        # Meet names transcript docs like "Title - Transcript" or
        # "Title (2026/06/27 17:00 GMT-7) - Transcript". Strip the "- Transcript" suffix and
        # ONLY a trailing parenthetical that is actually Meet's date/time stamp — a date
        # (Y/M/D), a clock time (HH:MM), or a "GMT" marker. A real parenthetical like
        # "Roadmap (Q3 2026)", "Planning (3 items)" or "Sync (NYC)" is preserved, because the
        # cleaned title is the key the Drive Calendar enricher matches on.
        DATE_STAMP = %r{\s*\((?:\d{2,4}[/-]\d{1,2}[/-]\d{1,2}|\d{1,2}:\d{2}|[^)]*\bGMT\b)[^)]*\)\s*\z}
        def clean_title(name)
          name.to_s
              .sub(/\s*-\s*Transcript\s*\z/i, '')
              .sub(DATE_STAMP, '')
              .strip
              .presence || name.to_s
        end

        # A speaker line is "Name: <text>". The name must LOOK like a name: capitalized
        # words, initials ("J.R."), or a "(Guest)"-style label, joined by spaces, commas
        # or "&". Requiring a name-shaped prefix (not just "anything before a colon")
        # rejects spoken sentences that happen to contain a colon — e.g.
        # "I think the answer is: yes" — which would otherwise become phantom speakers and
        # inflate the distinct-speaker count the 1:1 privacy classifier falls back on.
        NAME_WORD = /(?:\p{Lu}[\p{L}.'’-]*|\([^)]*\))/
        SPEAKER_LINE = /\A\s*(#{NAME_WORD}(?:[ ,&]+#{NAME_WORD}){0,4}):\s+(\S.*)\z/

        def parse_segments(text)
          segments = []
          text.to_s.each_line do |raw|
            line = raw.chomp
            if (m = line.match(SPEAKER_LINE))
              segments << { speaker_name: m[1].strip, speaker_email: nil, text: m[2].strip, started_at: nil, ended_at: nil }
            elsif segments.any? && line.strip.present?
              # A non-speaker line is a wrapped continuation of the current turn — append it
              # rather than dropping it, so long utterances keep their full text.
              segments.last[:text] = "#{segments.last[:text]} #{line.strip}".strip
            end
            # A non-matching line before the first speaker (header/preamble) is ignored.
          end
          segments
        end

        def build_meeting(doc, file, segments, title)
          meeting = Meeting.find_or_initialize_by(drive_transcript_doc_id: file.id)
          meeting.update!(meet_source: :drive, title: title, started_at: file.created_time,
                          participant_count: segments.map { |s| s[:speaker_name] }.compact.uniq.size,
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
