class ProfitShare < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include SyncsAsQboBill

  belongs_to :periodic_report

  before_destroy :detach_and_destroy_qbo_bill

  def applied_at
    periodic_report.period.ends_at
  end

  def effective_on_for_display
    applied_at
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

  # Profit-share bills accrue to the dedicated liability account so finance
  # can track total profit-sharing exposure separately from contractor
  # expenses. Match by `acct_num` (canonical chart-of-accounts identifier,
  # more stable than name across rename events). Falls back to the
  # default SyncsAsQboBill routing if the account doesn't exist in QBO.
  PROFIT_SHARE_LIABILITY_ACCT_NUM = "2340".freeze  # Accrued Profit Sharing

  def find_qbo_account!(qbo_accounts = nil)
    qa = qbo_account_for_bill
    raise "Enterprise has no qbo_account" if qa.nil?
    qbo_accounts ||= qa.fetch_all_accounts
    specific = qbo_accounts.find { |a| a.respond_to?(:acct_num) && a.acct_num == PROFIT_SHARE_LIABILITY_ACCT_NUM }
    return [specific, nil] if specific.present?
    super(qbo_accounts)
  end

  def in_balance_under_qbo_bound?
    payable? && !qbo_bill&.paid?
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
