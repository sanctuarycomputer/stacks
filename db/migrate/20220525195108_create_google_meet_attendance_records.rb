class CreateGoogleMeetAttendanceRecords < ActiveRecord::Migration[6.0]
  def change
    create_table :google_meet_attendance_records do |t|
      t.string :google_endpoint_id, null: false
      t.string :google_calendar_event_id, null: false
      t.string :participant_id, null: false
    end

    add_index :google_meet_attendance_records, :google_endpoint_id, unique: true
  end
end
