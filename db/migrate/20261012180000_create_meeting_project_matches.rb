# Which project tracker(s) a Google Meet meeting was about, decided nightly by
# Stacks::Meetings::ProjectMatcher and correctable by a person. Keyed on the
# meeting: its transcript and its Gemini notes are two documents of one Meeting.
class CreateMeetingProjectMatches < ActiveRecord::Migration[6.1]
  def change
    create_table :meeting_project_trackers do |t|
      t.references :meeting, null: false, foreign_key: true
      t.references :project_tracker, null: false, foreign_key: true
      t.integer :matched_by, null: false, default: 0
      t.float :confidence
      t.text :rationale
      t.timestamps
      t.index [:meeting_id, :project_tracker_id], unique: true, name: "index_meeting_project_trackers_on_meeting_and_tracker"
    end

    create_table :meeting_project_scans do |t|
      t.references :meeting, null: false, foreign_key: true, index: { unique: true }
      t.integer :outcome, null: false
      t.string :scanned_hash
      t.datetime :scanned_at, null: false
      t.boolean :human_locked, null: false, default: false
      t.timestamps
    end
  end
end
