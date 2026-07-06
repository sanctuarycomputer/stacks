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
            Array(resp.files).each { |f| records_for(f).each { |r| yield r } }
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

        # A combined "Notes by Gemini" file yields TWO records (transcript first so the notes'
        # for_drive_doc(file.id) join resolves it at ingest); a plain/old-format notes doc yields
        # one. When combined, the notes body excludes the embedded transcript.
        def records_for(file)
          text = @service.export_file(file.id, "text/markdown")
          if combined_format?(text, file.id)
            notes_md, transcript_md = split_transcript(text)
            segments = parse_segments(transcript_md).each { |s| s[:started_at] = coerce(file.created_time) }
            if segments.any?
              tx = transcript_record(file, text, transcript_md, segments)
              # Reverse-dedup: if an API/Drive transcript Document already covers this file, don't
              # emit a duplicate transcript — the notes still inherit from it at ingest.
              [tx, note_record(file, notes_md, text)].compact
            else
              [note_record(file, notes_md, text)] # empty transcript -> notes-only
            end
          else
            [normalize(file, exported: text)] # old-format / notes-only
          end
        end

        # The embedded transcript as its own source:meet record, keyed/deduped exactly like a
        # DriveSource transcript (external_id + drive_doc_id = file.id; classified by real
        # speakers). Returns nil when an existing transcript Document already covers file.id.
        def transcript_record(file, full_text, transcript_md, segments)
          return nil if Document.for_drive_doc(file.id).where.not(external_id: file.id).exists?
          title = clean_title(file.name)
          occurred_at = coerce(file.created_time)
          emails = invited_emails_from(full_text)
          speaker_count = distinct_speaker_count(segments)
          {
            source: :meet,
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: occurred_at,
            content_hash: Digest::SHA256.hexdigest(transcript_md.to_s),
            participant_count: speaker_count, # ACTUAL speakers drive the 1:1 head-count
            # Reuse the doc's Invited emails for attribution (no separate Calendar call needed);
            # attribution is separate from the speaker-based head-count above.
            contacts: emails.map { |e| { email: e, name: nil, role: "attendee" } },
            segments: segments,
            raw_metadata: { "drive_doc_id" => file.id, "combined_notes_doc_id" => file.id },
            build_source_record: ->(doc) { build_transcript_meeting(doc, file, title, occurred_at, speaker_count, segments) }
          }
        end

        # Meeting for the embedded transcript — keyed like DriveSource so notes join it.
        def build_transcript_meeting(doc, file, title, occurred_at, speaker_count, segments)
          meeting = Meeting.find_or_initialize_by(drive_transcript_doc_id: file.id)
          meeting.update!(meet_source: :drive, title: title, started_at: occurred_at,
                          participant_count: speaker_count,
                          raw_metadata: (meeting.raw_metadata || {}).merge("document_id" => doc.id))
          meeting.segments.destroy_all
          segments.each_with_index do |s, i|
            meeting.segments.create!(position: i, speaker_name: s[:speaker_name], text: s[:text], started_at: s[:started_at])
          end
          meeting
        end

        # The gemini_notes (notes-body) record. `notes_md` is the notes portion only (for a
        # combined doc that's everything before the transcript heading; for a plain doc it's the
        # whole export). `full_text` is the full export, used for the invited emails and the
        # transcript link.
        def note_record(file, notes_md, full_text)
          title = clean_title(file.name)
          occurred_at = coerce(file.created_time)
          transcript_id = transcript_doc_id_from(full_text)
          emails = invited_emails_from(full_text)
          segments = body_segments(notes_md, occurred_at: occurred_at)
          {
            source: :gemini_notes,
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: occurred_at,
            content_hash: Digest::SHA256.hexdigest(notes_md.to_s),
            contacts: emails.map { |e| { email: e, name: nil, role: "attendee" } },
            segments: segments,
            transcript_doc_id: transcript_id,
            participant_count: emails.size,
            raw_metadata: { "gemini_notes_doc_id" => file.id, "transcript_doc_id" => transcript_id },
            build_source_record: ->(doc) { build_meeting(doc, file, title, occurred_at, transcript_id) }
          }
        end

        # Old-format / notes-only: the notes body is the whole export.
        def normalize(file, exported: nil)
          text = exported || @service.export_file(file.id, "text/markdown")
          note_record(file, text, text)
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
