require 'digest'

module Stacks
  module Etl
    module Meet
      class MeetApiSource
        def initialize(admin_email)
          @admin_email = admin_email
          @service = Auth.meet_service(sub: admin_email)
        end

        def each_meeting
          page = nil
          loop do
            resp = @service.list_conference_records(page_token: page)
            Array(resp.conference_records).each { |cr| yield normalize(cr) }
            page = resp.next_page_token
            break unless page
          end
        end

        private

        def normalize(cr)
          participants = fetch_participants(cr.name)
          segments = fetch_segments(cr.name, participants)
          text = segments.map { |s| s[:text] }.join("\n")
          {
            external_id: cr.name,
            title: cr.space&.meeting_code,
            url: "https://meet.google.com/#{cr.space&.meeting_code}",
            occurred_at: cr.start_time,
            content_hash: Digest::SHA256.hexdigest(text),
            contacts: participants.values.map { |p| { email: p[:email], name: p[:name], role: 'participant' } },
            segments: segments,
            raw_metadata: { 'conference_record' => cr.name },
            build_source_record: ->(doc) { build_meeting(doc, cr, participants, segments) }
          }
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

        def fetch_segments(cr_name, participants)
          segments = []
          tpage = nil
          loop do
            tresp = @service.list_conference_record_transcripts(cr_name, page_token: tpage)
            Array(tresp.transcripts).each do |t|
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
          segments
        end

        def build_meeting(doc, cr, participants, segments)
          meeting = Meeting.find_or_initialize_by(meet_conference_record_id: cr.name)
          meeting.update!(meet_source: :meet_api, title: cr.space&.meeting_code, started_at: cr.start_time,
                          ended_at: cr.end_time, participant_count: participants.size,
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
