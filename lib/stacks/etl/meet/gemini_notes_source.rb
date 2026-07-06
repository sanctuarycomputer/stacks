require "digest"
module Stacks
  module Etl
    module Meet
      class GeminiNotesSource
        include DriveDoc
        include TranscriptSegments
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

        # The transcript is EMBEDDED in this notes doc (newer Meet format) when its
        # "Meeting records [Transcript](…/document/d/<id>)" link points to the doc's OWN id.
        def combined_format?(text, file_id)
          transcript_doc_id_from(text) == file_id
        end

        # First markdown heading whose text contains "Transcript" — tolerant of the 📖 emoji so
        # a future Google change doesn't break it. The inline "Meeting records [Transcript](…)"
        # link is NOT a heading and is not matched.
        TRANSCRIPT_HEADING = /^\#{1,2}\s+.*Transcript.*$/i

        # Split a combined doc into [notes_body_markdown, transcript_markdown]. Everything from
        # the transcript heading onward is the transcript; everything before is the notes body.
        # Returns transcript_md = "" when no transcript heading is present (caller falls back to
        # notes-only).
        def split_transcript(text)
          s = text.to_s
          if (m = s.match(TRANSCRIPT_HEADING))
            [s[0...m.begin(0)], s[m.begin(0)..]]
          else
            [s, ""]
          end
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
          # Export as MARKDOWN, not text/plain: Google's plain-text export STRIPS hyperlinks,
          # which would flatten the "Invited [Name](mailto:email)" list and the
          # "Meeting records [Transcript](…/document/d/<id>)" link to bare display text —
          # leaving us with no invited emails (→ participant_count 0 → wrongly auto-excluded)
          # and no transcript-doc-id to join on (→ every note falls to the standalone path).
          # Markdown preserves both link forms, which is what the parsers below depend on.
          # (Transcripts stay text/plain in DriveSource — speaker lines carry no links.)
          text = @service.export_file(file.id, "text/markdown")
          title = clean_title(file.name)
          occurred_at = coerce(file.created_time)
          transcript_id = transcript_doc_id_from(text)
          emails = invited_emails_from(text)
          segments = body_segments(text, occurred_at: occurred_at)

          {
            source: :gemini_notes,
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: occurred_at,
            content_hash: Digest::SHA256.hexdigest(text.to_s),
            contacts: emails.map { |e| { email: e, name: nil, role: "attendee" } },
            segments: segments,
            # transcript_doc_id drives BOTH inheritance (Connector#exclusion_for) and the
            # meeting-join (build_meeting), resolved at ingest via Document.for_drive_doc.
            transcript_doc_id: transcript_id,
            participant_count: emails.size, # standalone fallback when no transcript resolves
            raw_metadata: { "gemini_notes_doc_id" => file.id, "transcript_doc_id" => transcript_id },
            build_source_record: ->(doc) { build_meeting(doc, file, title, occurred_at, transcript_id) }
          }
        end

        def build_meeting(doc, file, title, occurred_at, transcript_id)
          # Resolve the joined meeting at INGEST time so a same-sweep combined transcript
          # (yielded just before us) is found. for_drive_doc matches DriveSource (external_id)
          # and MeetApiSource (raw_metadata.drive_doc_id) keying.
          joined = transcript_id && Document.for_drive_doc(transcript_id).first&.source_record
          meeting = joined || Meeting.find_or_initialize_by(gemini_notes_doc_id: file.id)
          meeting.update!(meet_source: (joined ? meeting.meet_source : :gemini_notes),
                          title: title, started_at: occurred_at,
                          gemini_notes_doc_id: file.id,
                          raw_metadata: (meeting.raw_metadata || {}).merge("gemini_notes_document_id" => doc.id))
          meeting
        end
      end
    end
  end
end
