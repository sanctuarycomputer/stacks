# Nightly mirror of Runn roles. standard_rate is the client BILL rate the
# Forecast->Runn actuals sync writes ("$195.00 p/h" roles); default_hour_cost
# is 0 on those roles. Never pruned.
class RunnRole < ApplicationRecord
  self.primary_key = "runn_id"
  has_many :runn_assignments, foreign_key: :role_id, primary_key: :runn_id
end
