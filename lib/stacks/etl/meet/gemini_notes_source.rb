require "digest"
module Stacks
  module Etl
    module Meet
      class GeminiNotesSource
        include DriveDoc
        include TranscriptSegments
        include NotesDoc
        QUERY = "mimeType='application/vnd.google-apps.document' and name contains 'Notes by Gemini'".freeze

        def initialize(user_email, since:, until_time: nil, parse_transcript: false)
          @user_email = user_email
          @since = coerce(since)
          @until_time = coerce(until_time)
          @parse_transcript = parse_transcript
          @service = Auth.drive_service(sub: user_email)
        end

        def each_meeting
          page = nil
          loop do
            q = "#{QUERY} and createdTime > '#{@since.utc.iso8601}'"
            q += " and createdTime < '#{@until_time.utc.iso8601}'" if @until_time
            resp = @service.list_files(q: q, fields: "nextPageToken, files(id,name,createdTime)", page_token: page)
            Array(resp.files).each do |f|
              # Daily mode: skip without exporting if a transcript Document already covers this file.
              # MeetApiSource (which runs first in sync_all) stores drive_doc_id in raw_metadata,
              # so for_drive_doc matches it. The export is expensive — skip before it.
              next if !@parse_transcript && Document.for_drive_doc(f.id).exists?
              records_for(f).each { |r| yield r }
            end
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

        # Real Gemini transcripts render each turn as BOLD markdown: "**Name:** utterance".
        # The shared speaker parser (from DriveSource's plain-text transcripts) expects a
        # letter-led "Name: utterance" line, so it matches ZERO bold turns. Strip the "**"
        # emphasis before parsing (validated on prod: 0 -> hundreds of turns, no false speakers).
        # DriveSource transcripts are plain text and never reach this path.
        def transcript_speaker_text(md)
          md.to_s.gsub("**", "")
        end


        # A combined "Notes by Gemini" file yields TWO records (transcript first so the notes'
        # for_drive_doc(file.id) join resolves it at ingest); a plain/old-format notes doc yields
        # one. When combined, the notes body excludes the embedded transcript.
        def records_for(file)
          text = @service.export_file(file.id, "text/markdown")
          unless @parse_transcript
            # Daily mode: emit notes-only from the notes portion. Use split_transcript so
            # a combined-format doc that slipped past the skip check doesn't pollute the
            # notes body with transcript text. Never call parse_segments / transcript_record.
            notes_md = split_transcript(text).first
            return [note_record(file, notes_md, text)]
          end
          # Backfill mode: full combined-doc handling (transcript-from-markdown + notes).
          if combined_format?(text, file.id)
            notes_md, transcript_md = split_transcript(text)
            segments = parse_segments(transcript_speaker_text(transcript_md)).each { |s| s[:started_at] = coerce(file.created_time) }
            if segments.any?
              tx = transcript_record(file, text, transcript_md, segments)
              [tx, note_record(file, notes_md, text)].compact
            else
              [note_record(file, notes_md, text)]
            end
          else
            [normalize(file, exported: text)]
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
          segments = notes_segments(notes_md, occurred_at: occurred_at)
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
