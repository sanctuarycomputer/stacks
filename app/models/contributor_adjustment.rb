class ContributorAdjustment < ApplicationRecord
  acts_as_paranoid

  belongs_to :contributor
  belongs_to :qbo_invoice, class_name: "QboInvoice", foreign_key: "qbo_invoice_id", primary_key: "qbo_id", optional: true

  # Match InvoiceTracker: ensure a local QboInvoice row exists so we can sync remote state (ad-hoc QBO invoices, not only system trackers).
  def qbo_invoice
    super || (qbo_invoice_id.present? ? QboInvoice.create!(qbo_id: qbo_invoice_id) : nil)
  end

  validates :amount, presence: true
  validates :effective_on, presence: true

  # No linked invoice: counts toward balance like other payable rows. Linked invoice: only when fully paid in QBO.
  def payable?
    return true if qbo_invoice_id.blank?

    inv = QboInvoice.find_by(qbo_id: qbo_invoice_id)
    inv.present? && inv.status == :paid
  end
end
