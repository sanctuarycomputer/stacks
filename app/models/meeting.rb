class Meeting < ApplicationRecord
  has_one :document, as: :source_record
  has_many :participants, class_name: 'MeetingParticipant', dependent: :destroy
  has_many :segments, class_name: 'MeetingTranscriptSegment', dependent: :destroy

  enum meet_source: { meet_api: 0, drive: 1 }
end
