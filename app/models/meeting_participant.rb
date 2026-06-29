class MeetingParticipant < ApplicationRecord
  belongs_to :meeting
  belongs_to :contact, optional: true
end
