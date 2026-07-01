require "digest"
module Stacks
  module Etl
    module Meet
      class GeminiNotesSource
        include DriveDoc
        QUERY = "mimeType='application/vnd.google-apps.document' and name contains 'Notes by Gemini'".freeze

        def initialize(user_email, since:, until_time: nil)
          @user_email = user_email
          @since = coerce(since)
          @until_time = coerce(until_time) # notes have no overlap guard; callers pass nil
          @service = Auth.drive_service(sub: user_email)
        end

        def each_meeting
          page = nil
          loop do
            q = "#{QUERY} and createdTime > '#{@since.utc.iso8601}'"
            q += " and createdTime < '#{@until_time.utc.iso8601}'" if @until_time
            resp = @service.list_files(q: q, fields: "nextPageToken, files(id,name,createdTime)", page_token: page)
            Array(resp.files).each { |f| yield normalize(f) }
            page = resp.next_page_token
            break unless page
          end
        end

        private

        def transcript_doc_id_from(text)
          # The "Meeting records [Transcript](…/document/d/<id>/…)" line.
          m = text.to_s.match(%r{\[Transcript\]\(https://docs\.google\.com/document/d/([A-Za-z0-9_-]+)})
          m && m[1]
        end

        def invited_emails_from(text)
          # Emails only appear as mailto: links, primarily in the "Invited" block.
          text.to_s.scan(/mailto:([^)\s]+)/).flatten.map { |e| e.downcase }
              .reject { |e| e.end_with?("resource.calendar.google.com") }.uniq
        end

        def body_segments(text, occurred_at:)
          # Search-only: the whole notes body IS the searchable content. Split into
          # paragraph-ish blocks so the Chunker has natural boundaries; drop the trailing
          # Gemini feedback/footer noise.
          cleaned = text.to_s.gsub(/We['’]ve updated the Decisions section.*\z/m, "")
                        .gsub(/Let us know what you think.*\z/m, "")
                        .gsub(/You should review Gemini['’]s notes.*\z/m, "")
          cleaned.split(/\n{2,}/).map(&:strip).reject(&:empty?).map do |para|
            { speaker_name: nil, speaker_email: nil, text: para, started_at: occurred_at, ended_at: nil }
          end
        end

        def normalize(file)
          text = @service.export_file(file.id, "text/plain")
          title = clean_title(file.name)
          occurred_at = coerce(file.created_time)
          transcript_id = transcript_doc_id_from(text)
          emails = invited_emails_from(text)
          segments = body_segments(text, occurred_at: occurred_at)

          # Join to the transcript's meeting when we ingested that transcript.
          # Use for_drive_doc so we match BOTH ingest shapes: DriveSource keys on external_id,
          # MeetApiSource keys on the conference-record id and stores the Drive id in raw_metadata.
          transcript_doc = transcript_id && Document.for_drive_doc(transcript_id).first
          meeting = transcript_doc&.source_record

          base = {
            source: :gemini_notes,
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: occurred_at,
            content_hash: Digest::SHA256.hexdigest(text.to_s),
            contacts: emails.map { |e| { email: e, name: nil, role: "attendee" } },
            segments: segments,
            raw_metadata: { "gemini_notes_doc_id" => file.id, "transcript_doc_id" => transcript_id },
            build_source_record: ->(doc) { build_meeting(doc, file, title, occurred_at, meeting) }
          }
          if meeting && transcript_doc
            # Inherit the transcript's decision verbatim (identical privacy wall).
            base.merge(inherit_exclusion: [transcript_doc.excluded.to_sym, transcript_doc.excluded_reason.to_sym])
          else
            base.merge(participant_count: emails.size) # standalone -> classify on invited count
          end
        end

        def build_meeting(doc, file, title, occurred_at, joined_meeting)
          meeting = joined_meeting || Meeting.find_or_initialize_by(gemini_notes_doc_id: file.id)
          meeting.update!(meet_source: (joined_meeting ? meeting.meet_source : :gemini_notes),
                          title: title, started_at: occurred_at,
                          gemini_notes_doc_id: file.id,
                          raw_metadata: (meeting.raw_metadata || {}).merge("gemini_notes_document_id" => doc.id))
          meeting
        end
      end
    end
  end
end
