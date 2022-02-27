class ForecastPerson < ApplicationRecord
  self.primary_key = "forecast_id"
  has_many :forecast_assignments, class_name: "ForecastAssignment", foreign_key: "person_id"
  has_one :admin_user, class_name: "AdminUser", foreign_key: "email", primary_key: "email"
end
