class ForecastPersonCostWindow < ApplicationRecord
  belongs_to :forecast_person
  belongs_to :forecast_project
end
