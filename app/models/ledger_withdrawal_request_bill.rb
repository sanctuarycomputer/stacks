class LedgerWithdrawalRequestBill < ApplicationRecord
  belongs_to :ledger_withdrawal_request, inverse_of: :bills
  belongs_to :qbo_account

  validates :qbo_bill_id, presence: true
  validates :amount_snapshot, presence: true
  validates :qbo_bill_id, uniqueness: {
    scope: [:ledger_withdrawal_request_id, :qbo_account_id],
    message: "already attached to this request",
  }

  # Host classes that emit Bills through SyncsAsQboBill. Used by
  # #host_record to resolve which ledger item is being settled by this
  # row — that's how the Process via Deel description lists things like
  # "Contributor Payout" / "Pay Stub" instead of just bare QBO Bill ids.
  HOST_CLASSES = [
    ContributorPayout,
    ContributorAdjustment,
    ProfitShare,
    Trueup,
    PayStub,
  ].freeze

  # Resolve the local QboBill mirror via the composite (qbo_account_id, qbo_id)
  # key — same pattern SyncsAsQboBill hosts use. Memoized per instance.
  def qbo_bill
    return @_qbo_bill if defined?(@_qbo_bill)
    @_qbo_bill = QboBill.find_by(qbo_account_id: qbo_account_id, qbo_id: qbo_bill_id)
  end

  # Walks the SyncsAsQboBill host tables and returns the (ledger item) row
  # that pushed this QBO Bill. There's no reverse FK we can rely on, so
  # we look up by qbo_bill_id across each candidate class. Memoized.
  def host_record
    return @_host_record if defined?(@_host_record)
    @_host_record = HOST_CLASSES.lazy.filter_map do |klass|
      klass.find_by(qbo_bill_id: qbo_bill_id)
    end.first
  end

  # Human label for the host class, falling back to "QBO Bill" if we can't
  # resolve which host emitted it (e.g. mirror existed at request time but
  # the host row has since been hard-deleted).
  def host_label
    host_record ? host_record.class.name.titleize : "QBO Bill"
  end

  def host_effective_on
    return nil unless host_record.respond_to?(:effective_on_for_display)
    host_record.effective_on_for_display
  end

  # "Paid in QBO" is the source of truth. Defer to the QboBill mirror's
  # status field, which the daily sync updates from QBO.
  def paid?
    qbo_bill&.paid? || false
  end
end
