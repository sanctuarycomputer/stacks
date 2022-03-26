class QboInvoice < ApplicationRecord
  def data
    super || sync!.data
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
    invoice = Stacks::Quickbooks.fetch_invoice_by_id(qbo_id)
    update! data: invoice.as_json
    self
  end
end
