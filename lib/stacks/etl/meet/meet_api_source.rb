require 'digest'

module Stacks
  module Etl
    module Meet
      class MeetApiSource
        def initialize(admin_email, since: nil)
          @admin_email = admin_email
          @since = since.is_a?(String) ? Time.parse(since) : since
          @service = Auth.meet_service(sub: admin_email)
          @enricher = CalendarEnricher.new(admin_email)
        end

        def each_meeting
          page = nil
          loop do
            opts = { page_token: page }
            opts[:filter] = "start_time >= \"#{@since.utc.iso8601}\"" if @since
            resp = @service.list_conference_records(**opts)
            Array(resp.conference_records).each do |cr|
              normalized = normalize(cr)
              yield normalized if normalized # skip meetings with no transcript yet
            end
            page = resp.next_page_token
            break unless page
          end
        end

        private

        def normalize(cr)
          participants = fetch_participants(cr.name)
          segments, drive_doc_id = fetch_segments(cr.name, participants)
          # No transcript yet (still generating, or none): skip. The cursor LOOKBACK
          # re-checks recent meetings on later runs, so we pick it up once it's ready.
          return nil if segments.empty?
          # If the Drive backfill already ingested this exact transcript, defer to it —
          # don't create a duplicate. Read-only existence check (the shared Document scope
          # owns the key), NOT a merge. Exclude THIS meeting's own row (external_id ==
          # cr.name) — for_drive_doc also matches via raw_metadata.drive_doc_id, so without
          # this a LOOKBACK re-scan would skip our own doc and never re-ingest a transcript
          # that finalized/corrected after first sighting.
          return nil if drive_doc_id &&
                        Document.for_drive_doc(drive_doc_id).where.not(external_id: cr.name).exists?

          text = segments.map { |s| s[:text] }.join("\n")
          code, uri = space_label(cr.space)
          enrichment = @enricher.enrich(started_at: cr.start_time, meeting_code: code, fallback_title: code || cr.space)
          title = enrichment[:title]
          # Prefer Calendar attendees (real emails -> resolved Contacts); fall back to
          # the Meet participant list (display names only) when there's no Calendar match.
          contacts =
            if enrichment[:attendees].any?
              enrichment[:attendees].map { |a| { email: a[:email], name: a[:name], role: 'attendee' } }
            else
              participants.values.map { |p| { email: p[:email], name: p[:name], role: 'participant' } }
            end
          {
            external_id: cr.name,
            title: title,
            url: uri || (code ? "https://meet.google.com/#{code}" : nil),
            occurred_at: cr.start_time,
            content_hash: Digest::SHA256.hexdigest(text),
            # Actual Meet participant count for exclusion (NOT contacts.size, which may be
            # the Calendar attendee list or a fallback speaker list).
            participant_count: participants.size,
            contacts: contacts,
            segments: segments,
            # drive_doc_id kept for reference only; Drive ingest is partitioned to an older
            # window so the two sources never produce the same meeting (no fragile merge).
            raw_metadata: { 'conference_record' => cr.name, 'space' => cr.space, 'drive_doc_id' => drive_doc_id },
            build_source_record: ->(doc) { build_meeting(doc, cr, participants, segments, title, enrichment[:organizer_email]) }
          }
        end

        # The Meet API returns cr.space as a resource-name STRING ("spaces/..."),
        # not an object — fetch the space for its human join code/uri (best-effort).
        def space_label(space_name)
          return [nil, nil] if space_name.to_s.empty?
          space = @service.get_space(space_name)
          [space.meeting_code, space.meeting_uri]
        rescue StandardError
          [nil, nil]
        end

        def fetch_participants(cr_name)
          map = {}
          page = nil
          loop do
            resp = @service.list_conference_record_participants(cr_name, page_token: page)
            Array(resp.participants).each do |p|
              map[p.name] = { name: p.signedin_user&.display_name, email: nil }
            end
            page = resp.next_page_token
            break unless page
          end
          map
        end

        # Returns [segments, drive_doc_id] — drive_doc_id is the transcript's Drive Doc
        # (docs_destination.document), the shared key for cross-source dedup.
        def fetch_segments(cr_name, participants)
          segments = []
          drive_doc_id = nil
          tpage = nil
          loop do
            tresp = @service.list_conference_record_transcripts(cr_name, page_token: tpage)
            Array(tresp.transcripts).each do |t|
              drive_doc_id ||= t.docs_destination&.document
              epage = nil
              loop do
                eresp = @service.list_conference_record_transcript_entries(t.name, page_size: 100, page_token: epage)
                Array(eresp.transcript_entries).each do |e|
                  speaker = participants[e.participant] || {}
                  segments << { speaker_name: speaker[:name], speaker_email: speaker[:email], text: e.text,
                                started_at: e.start_time, ended_at: e.end_time }
                end
                epage = eresp.next_page_token
                break unless epage
              end
            end
            tpage = tresp.next_page_token
            break unless tpage
          end
          [segments, drive_doc_id]
        end

        def build_meeting(doc, cr, participants, segments, title, organizer_email)
          meeting = Meeting.find_or_initialize_by(meet_conference_record_id: cr.name)
          meeting.update!(meet_source: :meet_api, title: title, started_at: cr.start_time,
                          ended_at: cr.end_time, participant_count: participants.size,
                          organizer_email: organizer_email,
                          raw_metadata: { 'document_id' => doc.id })
          meeting.participants.destroy_all
          participants.each_value { |p| meeting.participants.create!(name: p[:name], email: p[:email]) }
          meeting.segments.destroy_all
          segments.each_with_index do |s, i|
            meeting.segments.create!(position: i, speaker_name: s[:speaker_name], speaker_email: s[:speaker_email],
                                     started_at: s[:started_at], ended_at: s[:ended_at], text: s[:text])
          end
          meeting
        end
      end
    end
  end
end
