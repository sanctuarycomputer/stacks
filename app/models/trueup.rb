class Trueup < ApplicationRecord
  acts_as_paranoid

  belongs_to :invoice_pass
  belongs_to :contributor
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id", primary_key: "forecast_id", optional: true
  validates :amount, presence: true
  validates :description, presence: true

  def payment_date
    invoice_pass.start_of_month.end_of_month
  end
end
