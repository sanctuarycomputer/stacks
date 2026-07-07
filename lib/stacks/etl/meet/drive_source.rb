require 'digest'

module Stacks
  module Etl
    module Meet
      class DriveSource
        include DriveDoc
        include TranscriptSegments

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
