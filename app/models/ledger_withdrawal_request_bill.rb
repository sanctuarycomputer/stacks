class LedgerWithdrawalRequestBill < ApplicationRecord
  belongs_to :ledger_withdrawal_request, inverse_of: :bills
  belongs_to :qbo_account

  validates :qbo_bill_id, presence: true
  validates :amount_snapshot, presence: true
  validates :qbo_bill_id, uniqueness: {
    scope: [:ledger_withdrawal_request_id, :qbo_account_id],
    message: "already attached to this request",
  }

  # Resolve the local QboBill mirror via the composite (qbo_account_id, qbo_id)
  # key — same pattern SyncsAsQboBill hosts use. Memoized per instance.
  def qbo_bill
    return @_qbo_bill if defined?(@_qbo_bill)
    @_qbo_bill = QboBill.find_by(qbo_account_id: qbo_account_id, qbo_id: qbo_bill_id)
  end

  # "Paid in QBO" is the source of truth. Defer to the QboBill mirror's
  # status field, which the daily sync updates from QBO.
  def paid?
    qbo_bill&.paid? || false
  end
end
