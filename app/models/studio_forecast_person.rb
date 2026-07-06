class StudioForecastPerson < ApplicationRecord
  belongs_to :studio
  # Explicit primary_key matches ForecastPerson's own primary_key override
  # (self.primary_key = "forecast_id") — see the migration comment. Without
  # this, the association would still work today (Rails infers primary_key
  # from ForecastPerson.primary_key), but every sibling model in this app
  # (Contributor, Trueup, ContributorPayout, ForecastPersonUtilizationReport)
  # states it explicitly, so we do too for consistency and to avoid relying
  # on the implicit inference.
  belongs_to :forecast_person, primary_key: "forecast_id"
end
