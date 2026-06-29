require 'test_helper'
require 'ostruct'

class Stacks::Etl::Meet::MeetApiSourceTest < ActiveSupport::TestCase
  test 'normalizes a conference record into a document with segments' do
    # The real Meet API returns `space` as a resource-name STRING; the human join
    # code comes from a separate get_space call.
    cr = OpenStruct.new(name: 'conferenceRecords/1', start_time: '2026-01-01T09:00:00Z', end_time: '2026-01-01T09:30:00Z',
                        space: 'spaces/abc')
    transcript = OpenStruct.new(name: 'conferenceRecords/1/transcripts/1')
    entry = OpenStruct.new(participant: 'p1', text: 'we decided to ship', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    participant = OpenStruct.new(name: 'p1', signedin_user: OpenStruct.new(display_name: 'Drew'))

    svc = mock('svc')
    svc.stubs(:list_conference_records).returns(OpenStruct.new(conference_records: [cr], next_page_token: nil))
    svc.stubs(:get_space).with('spaces/abc').returns(OpenStruct.new(meeting_code: 'abc-defg-hjk', meeting_uri: 'https://meet.google.com/abc-defg-hjk'))
    svc.stubs(:list_conference_record_transcripts).returns(OpenStruct.new(transcripts: [transcript], next_page_token: nil))
    svc.stubs(:list_conference_record_transcript_entries).returns(OpenStruct.new(transcript_entries: [entry], next_page_token: nil))
    svc.stubs(:list_conference_record_participants).returns(OpenStruct.new(participants: [participant], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:meet_service).returns(svc)
    # Keep the test offline: no real Calendar enrichment call.
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: 'abc-defg-hjk', attendees: [])

    yielded = []
    Stacks::Etl::Meet::MeetApiSource.new('hugh@sanctuary.computer').each_meeting { |n| yielded << n }

    assert_equal 1, yielded.size
    n = yielded.first
    assert_equal 'conferenceRecords/1', n[:external_id]
    assert_equal 'abc-defg-hjk', n[:title]
    assert_equal 'we decided to ship', n[:segments].first[:text]
    meeting = n[:build_source_record].call(Document.create!(source: :meet, external_id: n[:external_id]))
    assert_equal 'conferenceRecords/1', meeting.meet_conference_record_id
    assert_equal 1, meeting.segments.count
  end
end
