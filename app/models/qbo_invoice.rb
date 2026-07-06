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

  # A QboInvoice is "orphan" iff no tracker / adjustment references its
  # exact (qbo_account_id, qbo_id) pair. Same qbo_id in a different qa is
  # not the same invoice (Deel-style ID collision), so we have to filter
  # on the pair, not on qbo_id alone.
  scope :orphans, -> {
    claimed = [
      *InvoiceTracker.where.not(qbo_invoice_id: nil).pluck(:qbo_account_id, :qbo_invoice_id),
      *AdhocInvoiceTracker.where.not(qbo_invoice_id: nil).pluck(:qbo_account_id, :qbo_invoice_id),
      *ContributorAdjustment.where.not(qbo_invoice_id: nil).pluck(:qbo_account_id, :qbo_invoice_id),
    ]
    scope = order(Arel.sql("data->>'doc_number'"))
    return scope if claimed.empty?
    values_sql = claimed.map { |qa, qid| "(#{qa.to_i}, #{connection.quote(qid)})" }.join(", ")
    scope.where("(qbo_invoices.qbo_account_id, qbo_invoices.qbo_id) NOT IN (#{values_sql})")
  }

  # Keep in sync by construction: open_receivables and
  # malformed_sent_receivables share this regex, so they can never drift
  # apart into overlapping or gapped predicates. Built via single-quoted
  # heredoc + #sub (not #{}-interpolation) so the backslashes in the regex
  # reach Postgres literally instead of being consumed by Ruby escaping.
  BALANCE_NUMERIC_SQL_REGEX = '^-?\d+(\.\d+)?$'.freeze

  # Synced, sent, still-owed invoices — filtered entirely in SQL. #data
  # lazily re-fetches from the QBO API when the stored jsonb is empty, so
  # any bulk read MUST use a scope like this one to avoid firing a live QBO
  # request per empty row. The ->> predicates below inherently exclude
  # NULL/empty jsonb (->> on NULL/missing yields NULL, never a match), which
  # is what guarantees #data's lazy live-QBO fetch can never fire from this
  # scope. The balance cast is wrapped in a CASE (Postgres does not
  # guarantee AND short-circuit order) so a non-numeric balance is excluded
  # rather than raising.
  scope :open_receivables, -> {
    where(<<~'SQL'.squish.sub('BALANCE_REGEX', BALANCE_NUMERIC_SQL_REGEX))
      qbo_invoices.data->>'due_date' IS NOT NULL
      AND qbo_invoices.data->>'email_status' = 'EmailSent'
      AND CASE WHEN qbo_invoices.data->>'balance' ~ 'BALANCE_REGEX'
               THEN (qbo_invoices.data->>'balance')::numeric > 0
               ELSE FALSE END
    SQL
  }

  # Complement of open_receivables for observability: SENT invoices excluded
  # for any reason other than being paid (numeric balance <= 0) are
  # malformed — missing due_date, missing balance, or a non-numeric balance.
  scope :malformed_sent_receivables, -> {
    where(<<~'SQL'.squish.sub('BALANCE_REGEX', BALANCE_NUMERIC_SQL_REGEX))
      qbo_invoices.data->>'email_status' = 'EmailSent'
      AND (
        qbo_invoices.data->>'due_date' IS NULL
        OR qbo_invoices.data->>'balance' IS NULL
        OR NOT (qbo_invoices.data->>'balance' ~ 'BALANCE_REGEX')
      )
    SQL
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
    customer_name = customer_ref["name"]
    "##{data.dig("doc_number")} (#{ActionController::Base.helpers.number_to_currency(data.dig("total"))}) - #{customer_name} (#{status.to_s.humanize})"
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
    ref = data.dig("customer_ref")
    # customer_ref can be malformed (e.g. a String) in synced jsonb; always
    # hand callers a Hash so none of them re-inherit the String#[] trap.
    return ref if ref.is_a?(Hash)
    unless ref.nil?
      Rails.logger.warn("[QboInvoice] id=#{id} qbo_id=#{qbo_id} has malformed customer_ref (#{ref.class}); treating as empty")
    end
    {}
  end

  # Destroying a QboInvoice cascades through the composite FK
  # (qbo_account_id, qbo_invoice_id) → qbo_invoices (qbo_account_id, qbo_id)
  # with ON DELETE SET NULL. Trackers / adjustments in OTHER qa's are
  # untouched by construction — only rows whose pair matches this row get
  # their qbo_invoice_id nulled.
  def sync!
    if qbo_id == ""
      destroy!
      return false
    end

    begin
      invoice = qbo_account.fetch_invoice_by_id(qbo_id)
      update! data: invoice.as_json
      self
    rescue => e
      destroy! if e.message.starts_with?("Object Not Found:")
      false
    end
  end
end
