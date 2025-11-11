class Trueup < ApplicationRecord
  acts_as_paranoid

  belongs_to :invoice_pass
  belongs_to :forecast_person

  validates :amount, presence: true
  validates :description, presence: true

  def payment_date
    invoice_pass.start_of_month.end_of_month
  end
end
