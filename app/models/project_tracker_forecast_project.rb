class ProjectTrackerForecastProject < ApplicationRecord
  belongs_to :project_tracker
  belongs_to :forecast_project
end
