class DropKeyMeetingAttendanceTables < ActiveRecord::Migration[6.0]
  def change
    drop_table :google_meet_attendance_records
    drop_table :google_calendar_events
    drop_table :google_calendars
    drop_table :studio_key_meetings
    drop_table :key_meetings

    Okr.where(datapoint: :key_meeting_attendance).destroy_all
  end
end
