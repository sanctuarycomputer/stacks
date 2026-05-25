class ContributorAdjustment < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include SyncsAsQboBill

  before_destroy :detach_and_destroy_qbo_bill

  belongs_to :qbo_account
  belongs_to :qbo_invoice, class_name: "QboInvoice", foreign_key: "qbo_invoice_id", primary_key: "qbo_id", optional: true

  # Direct (qbo_account_id, qbo_invoice_id) lookup — no chain through
  # ledger.enterprise. Composite FK at the DB level guarantees the (qa, qbo_id)
  # pair references a real row.
  def qbo_invoice
    return nil unless qbo_invoice_id.present? && qbo_account_id.present?
    QboInvoice.find_by(qbo_id: qbo_invoice_id, qbo_account_id: qbo_account_id)
  end

  validates :amount, presence: true
  validates :effective_on, presence: true
  validate :qbo_invoice_must_live_in_qbo_account

  # No linked invoice: counts toward balance like other payable rows. Linked invoice: only when fully paid in QBO.
  def payable?
    return true if qbo_invoice_id.blank?
    inv = qbo_invoice
    inv.present? && inv.status == :paid
  end

  private

  def qbo_invoice_must_live_in_qbo_account
    return if qbo_invoice_id.blank? || qbo_account_id.blank?
    return if QboInvoice.exists?(qbo_id: qbo_invoice_id, qbo_account_id: qbo_account_id)
    errors.add(:qbo_invoice_id, "no QboInvoice with qbo_id=#{qbo_invoice_id} exists in qbo_account #{qbo_account_id}")
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
