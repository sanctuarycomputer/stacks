class CreateGoogleCalendarEvents < ActiveRecord::Migration[6.0]
  def change
    create_table :google_calendar_events do |t|
      t.string :google_id, null: false
      t.references :google_calendar, null: false, foreign_key: true
      t.datetime :start
      t.datetime :end
      t.string :html_link
      t.string :status
      t.string :summary
      t.string :description
      t.string :recurrence
      t.string :recurring_event_id
    end

    add_index :google_calendar_events, :google_id, unique: true
  end
end
