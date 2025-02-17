class ForecastPersonUtilizationReport < ApplicationRecord
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id"
end
