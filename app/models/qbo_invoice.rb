class QboInvoice < ApplicationRecord
  # `qbo_id` is NO LONGER the primary key. Post the
  # ScopeQboRecordsByQboAccount migration, qbo_id is composite-unique with
  # qbo_account_id — multiple rows can share a qbo_id. Using qbo_id as the
  # AR primary key caused destroy! / update_all to silently delete or null
  # rows from other qbo_accounts. The auto-increment `id` is unique per row;
  # callers that need the QBO entity ID use `.qbo_id` explicitly. Mirrors
  # QboVendor (which dropped its own primary_key override earlier).
  belongs_to :qbo_account

  # DB enforces NOT NULL via the ScopeQboRecordsByQboAccount migration;
  # AR-level validation surfaces a clean message before the DB rejection.
  validates :qbo_account, presence: true

  scope :orphans, -> {
    where.not(qbo_id: [*InvoiceTracker.pluck(:qbo_invoice_id).compact, *AdhocInvoiceTracker.pluck(:qbo_invoice_id).compact])
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
      destroy_and_detach_trackers!
      return false
    end

    begin
      invoice = qbo_account.fetch_invoice_by_id(qbo_id)
      update! data: invoice.as_json
      self
    rescue => e
      destroy_and_detach_trackers! if e.message.starts_with?("Object Not Found:")
      false
    end
  end

  private

  # Detach only trackers whose effective qbo_account matches this row's, so
  # an "Object Not Found" against (qbo_id, this qa) doesn't clobber a
  # tracker that's correctly referencing the same qbo_id in a DIFFERENT qa.
  # The tracker's qa is computed from forecast_client.billing_enterprise, so
  # the scoping must happen in Ruby rather than SQL.
  def destroy_and_detach_trackers!
    ActiveRecord::Base.transaction do
      InvoiceTracker.where(qbo_invoice_id: qbo_id).find_each do |t|
        next unless t.qbo_account&.id == qbo_account_id
        t.update_columns(qbo_invoice_id: nil)
      end

      AdhocInvoiceTracker.where(qbo_invoice_id: qbo_id).find_each do |t|
        # AdhocInvoiceTracker doesn't have an enterprise hop today — its
        # qbo_invoice belongs_to has no qbo_account dynamism. Detach
        # unconditionally; if a multi-enterprise routing is added later
        # this should mirror InvoiceTracker's check.
        t.update_columns(qbo_invoice_id: nil)
      end

      # destroy! now operates on the auto-increment `id` primary key,
      # so it deletes only THIS row — not other (qbo_id, other_qa) rows.
      destroy!
    end
  end
end
