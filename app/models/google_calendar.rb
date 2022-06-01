class GoogleCalendar < ApplicationRecord
  has_many :google_calendar_events, dependent: :destroy
end
