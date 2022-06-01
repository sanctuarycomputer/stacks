class CreateKeyMeetings < ActiveRecord::Migration[6.0]
  def change
    create_table :key_meetings do |t|
      t.string :name, null: false
      t.timestamps
    end
  end
end
