class AddWorkCompletedAtToProjectTrackers < ActiveRecord::Migration[6.0]
  def change
    add_column :project_trackers, :work_completed_at, :datetime
  end
end
