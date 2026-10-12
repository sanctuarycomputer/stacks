# Which project tracker(s) a Google Meet meeting was about, decided nightly by
# Stacks::Meetings::Sweep and correctable by a person. Keyed on the meeting:
# its transcript and its Gemini notes are two documents of one Meeting.
#
# meetings_project_trackers is a pure join table (ProjectTracker
# has_and_belongs_to_many :meetings). meeting_scans is the sibling of
# ship_scans: one row per examined meeting, holding the model's one answer
# about it (confidence and reason).
class CreateMeetingMatches < ActiveRecord::Migration[6.1]
  def change
    create_table :meetings_project_trackers, id: false do |t|
      t.references :meeting, null: false, foreign_key: true, index: false
      t.references :project_tracker, null: false, foreign_key: true
      t.index [:meeting_id, :project_tracker_id], unique: true, name: "index_meetings_project_trackers_on_meeting_and_tracker"
    end

    create_table :meeting_scans do |t|
      t.references :meeting, null: false, foreign_key: true, index: { unique: true }
      t.integer :outcome, null: false
      t.float :confidence
      t.text :rationale
      t.string :scanned_hash
      t.datetime :scanned_at, null: false
      t.boolean :human_locked, null: false, default: false
      t.timestamps
    end
  end
end
