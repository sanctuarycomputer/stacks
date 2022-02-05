class ForecastClient < ApplicationRecord
  self.primary_key = "forecast_id"
  has_many :forecast_projects, class_name: "ForecastProject", foreign_key: "client_id"
end
