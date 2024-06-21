class CreateProjectTrackerRunnProjects < ActiveRecord::Migration[6.0]
  def change
    create_table :project_tracker_runn_projects do |t|
      t.references :project_tracker, null: false, foreign_key: true
      t.references :runn_project, null: false, foreign_key: true

      t.timestamps
    end
  end
end
