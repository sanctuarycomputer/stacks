class ProfitShare < ApplicationRecord
  acts_as_paranoid
  include SyncsAsQboBill

  belongs_to :periodic_report
  belongs_to :contributor
  belongs_to :qbo_bill, class_name: "QboBill", foreign_key: "qbo_bill_id", primary_key: "qbo_id", optional: true, dependent: :destroy

  def applied_at
    periodic_report.period.ends_at
  end

  def payable?
    periodic_report.all_profit_shares_accepted?
  end

  def accepted?
    accepted_at.present?
  end

  def toggle_acceptance!
    if accepted?
      update!(accepted_at: nil)
    else
      update!(accepted_at: DateTime.now)
    end
  end

  # SyncsAsQboBill contract
  def bill_txn_date
    applied_at
  end

  def bill_description
    "https://stacks.garden3d.net/admin/periodic_reports/#{periodic_report_id}"
  end

  def bill_doc_number_code
    "PS"
  end
end
