# frozen_string_literal: true

# Shared logic for models that reference a QboInvoice through a composite key
# (qbo_account_id, qbo_invoice_id) rather than a simple foreign key.
#
# Requirements for the including model:
#   - belongs_to :qbo_account
#   - belongs_to :qbo_invoice, class_name: "QboInvoice",
#                foreign_key: "qbo_invoice_id", primary_key: "qbo_id", optional: true
#   - columns: qbo_account_id, qbo_invoice_id
module HasQboInvoiceViaCompositeKey
  extend ActiveSupport::Concern

  included do
    validate :qbo_invoice_must_live_in_qbo_account
  end

  # Look up the QboInvoice using the composite key (qbo_account_id, qbo_invoice_id).
  #
  # The in-memory association target is trusted ONLY when it belongs to this
  # record's QuickBooks account. The belongs_to matches on qbo_id alone, and a
  # QuickBooks invoice id is unique only within one account, so a preload
  # (`includes(:qbo_invoice)`) can hand us another company's invoice with the
  # same id. Returning that would report its status and total as ours.
  def qbo_invoice
    in_memory = association(:qbo_invoice).target
    return in_memory if in_memory.present? && in_memory.qbo_account_id == qbo_account_id
    return nil unless qbo_invoice_id && qbo_account_id

    # Cache the lookup on the association target so repeated calls (payable?
    # → qbo_invoice gets hit hundreds of times when rendering ledger views)
    # don't re-query the same row. Also replaces a wrong-account target, with
    # nil when this account has no such invoice.
    result = QboInvoice.find_by(qbo_id: qbo_invoice_id, qbo_account_id: qbo_account_id)
    association(:qbo_invoice).target = result if result || in_memory.present?
    result
  end

  private

  def qbo_invoice_must_live_in_qbo_account
    return if qbo_invoice_id.blank? || qbo_account_id.blank?
    return if QboInvoice.exists?(qbo_id: qbo_invoice_id, qbo_account_id: qbo_account_id)
    errors.add(:qbo_invoice_id, "no QboInvoice with qbo_id=#{qbo_invoice_id} exists in qbo_account #{qbo_account_id}")
  end
end
