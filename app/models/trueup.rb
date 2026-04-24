class Trueup < ApplicationRecord
  acts_as_paranoid
  include SyncsAsQboBill

  belongs_to :invoice_pass
  belongs_to :contributor
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id", primary_key: "forecast_id", optional: true
  validates :amount, presence: true
  validates :description, presence: true
  belongs_to :qbo_bill, class_name: "QboBill", foreign_key: "qbo_bill_id", primary_key: "qbo_id", optional: true

  def payment_date
    invoice_pass.start_of_month.end_of_month
  end

  def payable?
    true
  end

  # SyncsAsQboBill contract
  def bill_txn_date
    invoice_pass.start_of_month.end_of_month
  end

  def bill_description
    "http://stacks.garden3d.net/admin/contributors/#{contributor.id}/trueups/#{id}"
  end

  def bill_doc_number_code
    "TU"
  end
end
