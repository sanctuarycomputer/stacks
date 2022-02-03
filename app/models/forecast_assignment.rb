class ForecastAssignment < ApplicationRecord
  self.primary_key = "forecast_id"
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "person_id"
  belongs_to :forecast_project, class_name: "ForecastProject", foreign_key: "project_id"
end
