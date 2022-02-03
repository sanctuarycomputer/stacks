class DropKeyConstraintOnProjectTrackerForecastProjects < ActiveRecord::Migration[6.0]
  def change
    remove_foreign_key :project_tracker_forecast_projects, :forecast_projects
  end
end
