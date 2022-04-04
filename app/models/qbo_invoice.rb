class QboInvoice < ApplicationRecord
  self.primary_key = "qbo_id"

  def data
    existing = super
    return existing if existing.present?
    sync! ? data : nil
  end

  def display_name
    "#{data.dig("doc_number")} - #{ActionController::Base.helpers.number_to_currency(data.dig("total"))}"
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
    data.dig("customer_ref")
  end

  def sync!
    begin
      invoice = Stacks::Quickbooks.fetch_invoice_by_id(qbo_id)
      update! data: invoice.as_json
      self
    rescue => e
      if e.message.starts_with?("Object Not Found:")
        ActiveRecord::Base.transaction do
          it = InvoiceTracker.find_by(qbo_invoice_id: id)
          it.update(qbo_invoice_id: nil) if it.present?
          it.reload if it.present?

          ait = AdhocInvoiceTracker.find_by(qbo_invoice_id: id)
          ait.update(qbo_invoice_id: nil) if ait.present?
          ait.reload if ait.present?

          self.destroy!
        end
      end
      false
    end
  end
end
