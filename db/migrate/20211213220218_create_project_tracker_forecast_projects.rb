class CreateProjectTrackerForecastProjects < ActiveRecord::Migration[6.0]
  def change
    create_table :project_tracker_forecast_projects do |t|
      t.references :project_tracker, null: false, foreign_key: true
      t.references :forecast_project, null: false, foreign_key: true

      t.timestamps
    end
  end
end
