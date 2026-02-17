class RecurringCharge < ApplicationRecord
  belongs_to :forecast_client, class_name: "ForecastClient", foreign_key: "forecast_client_id", primary_key: "forecast_id"
end
