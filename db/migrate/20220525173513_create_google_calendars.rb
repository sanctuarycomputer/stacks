class CreateGoogleCalendars < ActiveRecord::Migration[6.0]
  def change
    create_table :google_calendars do |t|
      t.string :google_id, null: false
      t.string :name
      t.string :sync_token
    end

    add_index :google_calendars, :google_id, unique: true
  end
end
