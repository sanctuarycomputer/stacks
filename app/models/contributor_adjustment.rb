class ContributorAdjustment < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include SyncsAsQboBill
  include HasQboInvoiceViaCompositeKey

  before_destroy :detach_and_destroy_qbo_bill

  belongs_to :qbo_account
  belongs_to :qbo_invoice, class_name: "QboInvoice", foreign_key: "qbo_invoice_id", primary_key: "qbo_id", optional: true

  validates :amount, presence: true
  validates :effective_on, presence: true
  # Only block CREATION of new negative CAs on qbo_bound ledgers. Historical
  # negative CAs that pre-date the cutover stay editable (otherwise even fixing
  # a typo in description fails). `skip_qbo_bound_negative_check` is a per-
  # instance bypass that RecurringLedgerAdjustment#materialize! sets so a
  # legacy-era recurring deduction keeps materializing after the ledger flips —
  # otherwise the recurring row would silently stop applying.
  attr_accessor :skip_qbo_bound_negative_check

  validate :no_negative_on_qbo_bound_ledger, on: :create

  def no_negative_on_qbo_bound_ledger
    return if skip_qbo_bound_negative_check
    return unless ledger&.qbo_bound? && amount&.negative?
    errors.add(
      :amount,
      "negative adjustments are not allowed on QBO-bound ledgers — mark the corresponding QBO bill Paid instead",
    )
  end

  # No linked invoice: counts toward balance like other payable rows. Linked invoice: only when fully paid in QBO.
  def payable?
    return true if qbo_invoice_id.blank?
    inv = qbo_invoice
    inv.present? && inv.status == :paid
  end

  public

  def effective_on_for_display
    effective_on
  end

  # SyncsAsQboBill contract
  def bill_txn_date
    effective_on
  end

  def bill_description
    "https://stacks.garden3d.net/admin/ledgers/#{ledger_id}/contributor_adjustments/#{id}"
  end

  def bill_doc_number_code
    "CA"
  end
end
