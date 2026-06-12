class Trueup < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include SyncsAsQboBill

  belongs_to :invoice_pass
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id", primary_key: "forecast_id", optional: true
  validates :amount, presence: true
  validates :description, presence: true

  def payment_date
    invoice_pass.start_of_month.end_of_month
  end

  def effective_on_for_display
    payment_date
  end

  def payable?
    true
  end

  # Trueups always represent settled income; no payable? gate.
  def in_balance_under_qbo_bound?
    !qbo_bill&.paid?
  end

  # SyncsAsQboBill contract
  def bill_txn_date
    invoice_pass.start_of_month.end_of_month
  end

  def bill_description
    "https://stacks.garden3d.net/admin/ledgers/#{ledger_id}/trueups/#{id}"
  end

  def bill_doc_number_code
    "TU"
  end
end
