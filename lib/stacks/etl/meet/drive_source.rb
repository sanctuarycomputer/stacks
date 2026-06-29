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
            Array(resp.files).each { |f| yield normalize(f) }
            page = resp.next_page_token
            break unless page
          end
        end

        private

        def normalize(file)
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
        # ONLY a trailing parenthetical that looks like Meet's date stamp (starts with a
        # digit / contains GMT) — so a real title like "Roadmap (Q3 2026)" or "Sync (NYC)"
        # keeps its parenthetical.
        def clean_title(name)
          name.to_s
              .sub(/\s*-\s*Transcript\s*\z/i, '')
              .sub(/\s*\((?:\d|[^)]*GMT)[^)]*\)\s*\z/, '')
              .strip
              .presence || name.to_s
        end

        # A speaker line is "Name: <text>" — the colon MUST be followed by whitespace.
        # That single requirement excludes URLs ("https://…", colon+slash) and timestamps
        # ("10:30 …", colon+digit) without over-constraining the name, so legitimate
        # speakers like "J.R.:" or "John Doe (Guest):" keep their lines (and their text).
        SPEAKER_LINE = /\A\s*([^:]{1,60}):\s+(\S.*)\z/

        def parse_segments(text)
          text.to_s.each_line.filter_map do |line|
            if (m = line.chomp.match(SPEAKER_LINE))
              { speaker_name: m[1].strip, speaker_email: nil, text: m[2].strip, started_at: nil, ended_at: nil }
            end
          end
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
