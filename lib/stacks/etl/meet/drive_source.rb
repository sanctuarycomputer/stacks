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
          segments = parse_segments(text)
          {
            external_id: file.id,
            title: file.name,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: file.created_time,
            content_hash: Digest::SHA256.hexdigest(text.to_s),
            contacts: segments.map { |s| { email: nil, name: s[:speaker_name], role: 'speaker' } }.uniq,
            segments: segments,
            raw_metadata: { 'drive_doc_id' => file.id },
            build_source_record: ->(doc) { build_meeting(doc, file, segments) }
          }
        end

        def parse_segments(text)
          text.to_s.each_line.filter_map do |line|
            if (m = line.chomp.match(/\A\s*([^:]{1,60}):\s*(.+)\z/))
              { speaker_name: m[1].strip, speaker_email: nil, text: m[2].strip, started_at: nil, ended_at: nil }
            end
          end
        end

        def build_meeting(doc, file, segments)
          meeting = Meeting.find_or_initialize_by(drive_transcript_doc_id: file.id)
          meeting.update!(meet_source: :drive, title: file.name, started_at: file.created_time,
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
