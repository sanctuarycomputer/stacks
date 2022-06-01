class KeyMeeting < ApplicationRecord
  has_many :studio_key_meetings, dependent: :delete_all
  has_many :studios, through: :studio_key_meetings
  accepts_nested_attributes_for :studio_key_meetings, allow_destroy: true

  def events
    GoogleCalendarEvent.where(summary: name)
  end

  def asdf
#http://localhost:3000/admin/google_calendars/1/google_calendar_events?q%5Bsummary_equals%5D=%F0%9F%91%A9%E2%80%8D%F0%9F%8C%BE+garden3d+retro
  end
end
