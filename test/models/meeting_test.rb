require 'test_helper'

class MeetingTest < ActiveSupport::TestCase
  test 'meeting owns a document as source_record and orders segments' do
    meeting = Meeting.create!(meet_conference_record_id: 'conferenceRecords/1', title: 'Standup', meet_source: :meet_api)
    Document.create!(source: :meet, external_id: 'conferenceRecords/1', source_record: meeting)
    meeting.segments.create!(position: 1, text: 'second', speaker_name: 'B')
    meeting.segments.create!(position: 0, text: 'first', speaker_name: 'A')
    assert_equal %w[first second], meeting.segments.order(:position).pluck(:text)
    assert_equal meeting, meeting.documents.find_by(source: :meet).source_record
  end

  test 'conference record id is unique when present' do
    Meeting.create!(meet_conference_record_id: 'conferenceRecords/9', meet_source: :meet_api)
    assert_raises(ActiveRecord::RecordNotUnique) do
      Meeting.create!(meet_conference_record_id: 'conferenceRecords/9', meet_source: :meet_api)
    end
  end

  test "a meeting can own a transcript and a notes document" do
    m = Meeting.create!(meet_source: :drive, drive_transcript_doc_id: "t1")
    t = Document.create!(source: :meet, external_id: "t1", source_record: m)
    n = Document.create!(source: :gemini_notes, external_id: "n1", source_record: m)
    assert_equal [t.id, n.id].sort, m.documents.pluck(:id).sort
    assert_equal 1, Document.sources["gemini_notes"]
    assert_equal 1, Chunk.sources["gemini_notes"]
    assert_equal 2, Meeting.meet_sources["gemini_notes"]
  end
end
