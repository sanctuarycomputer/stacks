class AddSnapshotToProjectTrackers < ActiveRecord::Migration[6.0]
  def change
    add_column :project_trackers, :snapshot, :jsonb, default: {}
  end
end
