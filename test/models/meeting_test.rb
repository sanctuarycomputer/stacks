require 'test_helper'

class MeetingTest < ActiveSupport::TestCase
  test 'meeting owns a document as source_record and orders segments' do
    meeting = Meeting.create!(meet_conference_record_id: 'conferenceRecords/1', title: 'Standup', meet_source: :meet_api)
    Document.create!(source: :meet, external_id: 'conferenceRecords/1', source_record: meeting)
    meeting.segments.create!(position: 1, text: 'second', speaker_name: 'B')
    meeting.segments.create!(position: 0, text: 'first', speaker_name: 'A')
    assert_equal %w[first second], meeting.segments.order(:position).pluck(:text)
    assert_equal meeting, meeting.document.source_record
  end

  test 'conference record id is unique when present' do
    Meeting.create!(meet_conference_record_id: 'conferenceRecords/9', meet_source: :meet_api)
    assert_raises(ActiveRecord::RecordNotUnique) do
      Meeting.create!(meet_conference_record_id: 'conferenceRecords/9', meet_source: :meet_api)
    end
  end
end
