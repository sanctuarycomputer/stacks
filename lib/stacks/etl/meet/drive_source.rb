require 'digest'

module Stacks
  module Etl
    module Meet
      class DriveSource
        QUERY = "mimeType='application/vnd.google-apps.document' and name contains 'Transcript'".freeze

        def initialize(user_email, since:)
          @user_email = user_email
          @since = since.is_a?(String) ? Time.parse(since) : since
          @service = Auth.drive_service(sub: user_email)
          @enricher = CalendarEnricher.new(user_email)
        end

        def each_meeting
          page = nil
          loop do
            resp = @service.list_files(
              q: "#{QUERY} and createdTime > '#{@since.utc.iso8601}'",
              fields: 'nextPageToken, files(id,name,createdTime)',
              page_token: page
            )
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
          contacts =
            if enrichment[:attendees].any?
              enrichment[:attendees].map { |a| { email: a[:email], name: a[:name], role: 'attendee' } }
            else
              segments.map { |s| { email: nil, name: s[:speaker_name], role: 'speaker' } }.uniq
            end
          {
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: file.created_time,
            content_hash: Digest::SHA256.hexdigest(text.to_s),
            contacts: contacts,
            segments: segments,
            raw_metadata: { 'drive_doc_id' => file.id },
            build_source_record: ->(doc) { build_meeting(doc, file, segments, title) }
          }
        end

        # Meet names transcript docs like "Title - Transcript" or
        # "Title (2026/06/27 17:00 GMT-7) - Transcript". Strip those to the real title.
        def clean_title(name)
          name.to_s
              .sub(/\s*-\s*Transcript\s*\z/i, '')
              .sub(/\s*\([^)]*\)\s*\z/, '')
              .strip
              .presence || name.to_s
        end

        def parse_segments(text)
          text.to_s.each_line.filter_map do |line|
            if (m = line.chomp.match(/\A\s*([^:]{1,60}):\s*(.+)\z/))
              { speaker_name: m[1].strip, speaker_email: nil, text: m[2].strip, started_at: nil, ended_at: nil }
            end
          end
        end

        def build_meeting(doc, file, segments, title)
          meeting = Meeting.find_or_initialize_by(drive_transcript_doc_id: file.id)
          meeting.update!(meet_source: :drive, title: title, started_at: file.created_time,
                          participant_count: segments.map { |s| s[:speaker_name] }.uniq.size,
                          raw_metadata: { 'document_id' => doc.id })
          meeting.segments.destroy_all
          segments.each_with_index do |s, i|
            meeting.segments.create!(position: i, speaker_name: s[:speaker_name], text: s[:text])
          end
          meeting
        end
      end
    end
  end
end
