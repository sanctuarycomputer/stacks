class ContributorAdjustment < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include SyncsAsQboBill

  before_destroy :detach_and_destroy_qbo_bill

  belongs_to :qbo_invoice, class_name: "QboInvoice", foreign_key: "qbo_invoice_id", primary_key: "qbo_id", optional: true
  # Match InvoiceTracker: ensure a local QboInvoice row exists so we can sync remote state (ad-hoc QBO invoices, not only system trackers).
  # We bypass the belongs_to-generated super reader (which uses primary_key: qbo_id
  # and therefore performs a global, unscoped lookup) and instead scope explicitly by
  # qbo_account so the (qbo_account_id, qbo_id) composite index is used correctly.
  def qbo_invoice
    return nil unless qbo_invoice_id.present?
    qa = enterprise&.qbo_account
    return nil if qa.nil?
    QboInvoice.find_or_create_by!(qbo_id: qbo_invoice_id, qbo_account: qa)
  end

  validates :amount, presence: true
  validates :effective_on, presence: true

  # No linked invoice: counts toward balance like other payable rows. Linked invoice: only when fully paid in QBO.
  def payable?
    return true if qbo_invoice_id.blank?

    qa = enterprise&.qbo_account
    return false if qa.nil?
    inv = QboInvoice.find_by(qbo_id: qbo_invoice_id, qbo_account: qa)
    inv.present? && inv.status == :paid
  end

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
