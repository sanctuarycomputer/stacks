class ProjectTrackerForecastProject < ApplicationRecord
  belongs_to :project_tracker
  belongs_to :forecast_project, primary_key: :forecast_id
  validates :forecast_project, uniqueness: true

  def migrate
    fp = ForecastProject.where(id: forecast_project_id).first
    return if fp.nil?
    update(forecast_project_id: fp.forecast_id)
  end
end
