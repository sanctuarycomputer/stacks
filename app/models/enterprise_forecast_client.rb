class EnterpriseForecastClient < ApplicationRecord
  belongs_to :enterprise
  belongs_to :forecast_client, primary_key: :forecast_id, foreign_key: :forecast_client_id
end
