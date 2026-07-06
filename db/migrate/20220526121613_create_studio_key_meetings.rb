class CreateStudioKeyMeetings < ActiveRecord::Migration[6.0]
  def change
    create_table :studio_key_meetings do |t|
      t.references :studio, null: false, foreign_key: true
      t.references :key_meeting, null: false, foreign_key: true

      t.timestamps
    end
  end
end
