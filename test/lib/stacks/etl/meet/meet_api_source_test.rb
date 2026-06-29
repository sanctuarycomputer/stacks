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

  test 'keys on the conference record (Drive doc id only in metadata) and reports real participant_count' do
    cr = OpenStruct.new(name: 'conferenceRecords/9', start_time: '2026-01-01T09:00:00Z', end_time: '2026-01-01T09:30:00Z', space: 'spaces/abc')
    transcript = OpenStruct.new(name: 'conferenceRecords/9/transcripts/1', docs_destination: OpenStruct.new(document: 'DRIVE_DOC_42'))
    entry = OpenStruct.new(participant: 'p1', text: 'hello', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    parts = %w[p1 p2 p3].map { |n| OpenStruct.new(name: n, signedin_user: OpenStruct.new(display_name: n.upcase)) }
    svc = mock('svc')
    svc.stubs(:list_conference_records).returns(OpenStruct.new(conference_records: [cr], next_page_token: nil))
    svc.stubs(:get_space).returns(OpenStruct.new(meeting_code: 'abc', meeting_uri: 'u'))
    svc.stubs(:list_conference_record_transcripts).returns(OpenStruct.new(transcripts: [transcript], next_page_token: nil))
    svc.stubs(:list_conference_record_transcript_entries).returns(OpenStruct.new(transcript_entries: [entry], next_page_token: nil))
    svc.stubs(:list_conference_record_participants).returns(OpenStruct.new(participants: parts, next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:meet_service).returns(svc)
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: 'T', attendees: [{ email: 'a@x.co', name: 'A' }])

    n = nil
    Stacks::Etl::Meet::MeetApiSource.new('hugh@sanctuary.computer').each_meeting { |m| n = m }
    assert_equal 'conferenceRecords/9', n[:external_id]
    assert_equal 'DRIVE_DOC_42', n[:raw_metadata]['drive_doc_id']
    assert_equal 3, n[:participant_count] # actual Meet participants, not the 1 attendee
    meeting = n[:build_source_record].call(Document.create!(source: :meet, external_id: n[:external_id]))
    assert_equal 'conferenceRecords/9', meeting.meet_conference_record_id
    assert_nil meeting.drive_transcript_doc_id
  end

  test 'skips a record whose transcript Drive doc was already ingested by the Drive backfill' do
    # The Drive backfill already created a Document keyed on this transcript's Drive doc id.
    Document.create!(source: :meet, external_id: 'DRIVE_DOC_DUP')
    cr = OpenStruct.new(name: 'conferenceRecords/dup', start_time: '2026-01-01T09:00:00Z', end_time: '2026-01-01T09:30:00Z', space: 'spaces/abc')
    transcript = OpenStruct.new(name: 'conferenceRecords/dup/transcripts/1', docs_destination: OpenStruct.new(document: 'DRIVE_DOC_DUP'))
    entry = OpenStruct.new(participant: 'p1', text: 'hello', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    participant = OpenStruct.new(name: 'p1', signedin_user: OpenStruct.new(display_name: 'Drew'))
    svc = mock('svc')
    svc.stubs(:list_conference_records).returns(OpenStruct.new(conference_records: [cr], next_page_token: nil))
    svc.stubs(:get_space).returns(OpenStruct.new(meeting_code: 'abc', meeting_uri: 'u'))
    svc.stubs(:list_conference_record_transcripts).returns(OpenStruct.new(transcripts: [transcript], next_page_token: nil))
    svc.stubs(:list_conference_record_transcript_entries).returns(OpenStruct.new(transcript_entries: [entry], next_page_token: nil))
    svc.stubs(:list_conference_record_participants).returns(OpenStruct.new(participants: [participant], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:meet_service).returns(svc)
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: 'T', attendees: [])

    yielded = []
    Stacks::Etl::Meet::MeetApiSource.new('hugh@sanctuary.computer').each_meeting { |m| yielded << m }
    assert_empty yielded # defers to the existing Drive Document; no duplicate
  end

  test 're-scan does NOT skip the API meeting it ingested itself (re-ingests finalized transcripts)' do
    # The API keyed its own Document on the conference record and stored drive_doc_id in
    # raw_metadata. for_drive_doc would match that row, so the self-exclusion must let the
    # LOOKBACK re-scan through to re-detect a content_hash change.
    Document.create!(source: :meet, external_id: 'conferenceRecords/self',
                     raw_metadata: { 'drive_doc_id' => 'DOC_SELF' })
    cr = OpenStruct.new(name: 'conferenceRecords/self', start_time: '2026-01-01T09:00:00Z', end_time: '2026-01-01T09:30:00Z', space: 'spaces/abc')
    transcript = OpenStruct.new(name: 'conferenceRecords/self/transcripts/1', docs_destination: OpenStruct.new(document: 'DOC_SELF'))
    entry = OpenStruct.new(participant: 'p1', text: 'still talking', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    participant = OpenStruct.new(name: 'p1', signedin_user: OpenStruct.new(display_name: 'Drew'))
    svc = mock('svc')
    svc.stubs(:list_conference_records).returns(OpenStruct.new(conference_records: [cr], next_page_token: nil))
    svc.stubs(:get_space).returns(OpenStruct.new(meeting_code: 'abc', meeting_uri: 'u'))
    svc.stubs(:list_conference_record_transcripts).returns(OpenStruct.new(transcripts: [transcript], next_page_token: nil))
    svc.stubs(:list_conference_record_transcript_entries).returns(OpenStruct.new(transcript_entries: [entry], next_page_token: nil))
    svc.stubs(:list_conference_record_participants).returns(OpenStruct.new(participants: [participant], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:meet_service).returns(svc)
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: 'T', attendees: [])

    yielded = []
    Stacks::Etl::Meet::MeetApiSource.new('hugh@sanctuary.computer').each_meeting { |m| yielded << m }
    assert_equal ['conferenceRecords/self'], yielded.map { |n| n[:external_id] } # re-yielded, not self-skipped
  end

  test 'skips a conference record whose transcript has no entries yet' do
    cr = OpenStruct.new(name: 'conferenceRecords/empty', start_time: '2026-01-01T09:00:00Z', end_time: '2026-01-01T09:30:00Z', space: 'spaces/abc')
    svc = mock('svc')
    svc.stubs(:list_conference_records).returns(OpenStruct.new(conference_records: [cr], next_page_token: nil))
    svc.stubs(:list_conference_record_transcripts).returns(OpenStruct.new(transcripts: [], next_page_token: nil))
    svc.stubs(:list_conference_record_participants).returns(OpenStruct.new(participants: [], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:meet_service).returns(svc)

    yielded = []
    Stacks::Etl::Meet::MeetApiSource.new('hugh@sanctuary.computer').each_meeting { |m| yielded << m }
    assert_empty yielded
  end
end
