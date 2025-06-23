class MiscPayment < ApplicationRecord
  acts_as_paranoid
  validates :amount, presence: true
  validates :paid_at, presence: true

  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id"
end