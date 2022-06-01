class GoogleCalendarEvent < ApplicationRecord
  self.primary_key = "google_id"
  belongs_to :google_calendar
  has_many :google_meet_attendance_records, class_name: "GoogleMeetAttendanceRecord", foreign_key: "google_calendar_event_id"

  scope :cancelled, -> {
    where(status: "cancelled")
  }
  scope :confirmed, -> {
    where(status: "confirmed")
  }

  def past?
    self.end < DateTime.now
  end

  def key_meeting
    KeyMeeting.where(name: summary).first
  end

  def attendance_rate
    record = attendance
    expected_count = record.values.select{|v| v != :likely_ooo}.count
    ((record.values.select{|v| v == :attended}.count / expected_count.to_f) * 100).round(2)
  end

  def attendance
    km = key_meeting
    return {} unless key_meeting.present?

    expected_attendees = km
      .studios
      .map{|s| s.core_members_active_on(start.to_date) }
      .flatten
      .uniq

    expected_attendees.reduce({}) do |acc, a|
      has_record = google_meet_attendance_records.find do |r|
        r.participant_id === a.email
      end.present?

      if has_record
        acc[a] = :attended
        next acc
      end

      first_name = if a.info.is_a?(String)
                      a.email.split("@")[0].split(".")[0]
                    else
                      a.info.dig("first_name") || a.email.split("@")[0].split(".")[0]
                    end
      pto_records =
        GoogleCalendarEvent
          .where('summary ILIKE ? OR summary ILIKE ?', first_name + ' ooo', first_name + ' pto')
          .where('google_calendar_events.end >= ? AND google_calendar_events.start <= ?', self.start, self.end)
          .count

      if pto_records > 0
        acc[a] = :likely_ooo
        next acc
      end

      acc[a] = :no_attendance_record
      acc
    end
  end
end
