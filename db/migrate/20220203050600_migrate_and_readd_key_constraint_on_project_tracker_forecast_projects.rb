class MigrateAndReaddKeyConstraintOnProjectTrackerForecastProjects < ActiveRecord::Migration[6.0]
  def change
    ProjectTrackerForecastProject.all.each do |ptfp|
      ptfp.migrate
    end

    add_foreign_key :project_tracker_forecast_projects, :forecast_projects, column: :forecast_project_id, primary_key: "forecast_id"
  end
end
