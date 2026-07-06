class CreateMeetTables < ActiveRecord::Migration[6.1]
  def change
    create_table :meetings do |t|
      t.string :meet_conference_record_id
      t.string :drive_transcript_doc_id
      t.integer :meet_source, null: false, default: 0
      t.string :title
      t.string :organizer_email
      t.datetime :started_at
      t.datetime :ended_at
      t.integer :participant_count
      t.jsonb :raw_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :meetings, :meet_conference_record_id, unique: true, where: 'meet_conference_record_id IS NOT NULL'
    add_index :meetings, :drive_transcript_doc_id, unique: true, where: 'drive_transcript_doc_id IS NOT NULL'

    create_table :meeting_participants do |t|
      t.references :meeting, null: false, foreign_key: true
      t.string :name
      t.string :email
      t.references :contact, null: true, foreign_key: true
      t.datetime :join_at
      t.datetime :leave_at
      t.timestamps
    end

    create_table :meeting_transcript_segments do |t|
      t.references :meeting, null: false, foreign_key: true
      t.string :speaker_name
      t.string :speaker_email
      t.references :speaker_contact, null: true, foreign_key: { to_table: :contacts }
      t.datetime :started_at
      t.datetime :ended_at
      t.integer :position, null: false
      t.text :text, null: false
      t.timestamps
    end
    add_index :meeting_transcript_segments, [:meeting_id, :position], unique: true
  end
end
