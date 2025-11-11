class QboInvoice < ApplicationRecord
  self.primary_key = "qbo_id"

  scope :orphans, -> {
    where.not(id: [*InvoiceTracker.pluck(:qbo_invoice_id).compact, *AdhocInvoiceTracker.pluck(:qbo_invoice_id).compact])
      .order(Arel.sql("data->>'doc_number'"))
  }

  def status
    if email_status == "EmailSent"
      overdue = (due_date - Date.today) < 0
      if balance == 0
        :paid
      elsif balance == total
        overdue ? :unpaid_overdue : :unpaid
      else
        overdue ? :partially_paid_overdue : :partially_paid
      end
    else
      if data["private_note"].present? && data["private_note"].downcase.include?("voided")
        :voided
      else
        :not_sent
      end
    end
  end

  def data
    existing = super
    return existing if existing.present?
    sync! ? data : {}
  end

  def display_name
    "##{data.dig("doc_number")} (#{ActionController::Base.helpers.number_to_currency(data.dig("total"))}) - #{data.dig("customer_ref", "name")} (#{status.to_s.humanize})"
  end

  def qbo_invoice_link
    "https://app.qbo.intuit.com/app/invoice?txnId=#{qbo_id}"
  end

  def email_status
    data.dig("email_status")
  end

  def due_date
    Date.parse(data.dig("due_date"))
  end

  def line_items
    data.dig("line_items")
  end

  def balance
    data.dig("balance").to_f
  end

  def total
    data.dig("total").to_f
  end

  def customer_ref
    data.dig("customer_ref") || {}
  end

  def sync!
    if qbo_id == ""
      ActiveRecord::Base.transaction do
        InvoiceTracker
          .where(qbo_invoice_id: id)
          .update_all(qbo_invoice_id: nil)

        AdhocInvoiceTracker
          .where(qbo_invoice_id: id)
          .update_all(qbo_invoice_id: nil)

        self.destroy!
      end
      return false
    end

    begin
      invoice = Stacks::Quickbooks.fetch_invoice_by_id(qbo_id)
      update! data: invoice.as_json
      self
    rescue => e
      if e.message.starts_with?("Object Not Found:")
        ActiveRecord::Base.transaction do
          InvoiceTracker
            .where(qbo_invoice_id: id)
            .update_all(qbo_invoice_id: nil)

          AdhocInvoiceTracker
            .where(qbo_invoice_id: id)
            .update_all(qbo_invoice_id: nil)

          self.destroy!
        end
      end
      false
    end
  end
end
