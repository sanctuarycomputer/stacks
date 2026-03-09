class ForecastPersonUtilizationReport < ApplicationRecord
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id"

  enum period_gradation: {
    year: 0,
    month: 1,
    quarter: 2,
    trailing_3_months: 3,
    trailing_4_months: 4,
    trailing_6_months: 5,
    trailing_12_months: 6
  }
end