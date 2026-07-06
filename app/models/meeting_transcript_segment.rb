class MeetingTranscriptSegment < ApplicationRecord
  belongs_to :meeting
  belongs_to :speaker_contact, class_name: 'Contact', optional: true
end
