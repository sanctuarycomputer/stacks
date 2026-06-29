class QboBill < ApplicationRecord
  self.primary_key = "qbo_id"
  belongs_to :qbo_account
  belongs_to :qbo_vendor, class_name: "QboVendor", foreign_key: "qbo_vendor_id", primary_key: "qbo_id"

  # Belt-and-suspenders: column is NOT NULL at the DB level (per the
  # ScopeQboRecordsByQboAccount migration) but we enforce presence at the
  # AR level too so .valid? surfaces a clean error before the DB rejects it.
  validates :qbo_account, presence: true
  validates :qbo_id, presence: true

  before_destroy :delete_qbo_bill!

  def qbo_url
    "https://qbo.intuit.com/app/bill?&txnId=#{qbo_id}"
  end

  # QBO realms allocate vendor ids independently, so the same `qbo_id` can
  # belong to different vendors across enterprises. The bare belongs_to is
  # unscoped (primary_key: "qbo_id" only), which would resolve to whichever
  # row AR finds first — potentially in a DIFFERENT QBO realm. This helper
  # scopes the lookup to THIS bill's qbo_account.
  def vendor
    return nil if qbo_vendor_id.blank?
    QboVendor.find_by(qbo_account_id: qbo_account_id, qbo_id: qbo_vendor_id)
  end

  # QBO Bills are settled when their balance hits zero (full or partial
  # payments are reflected by BillPayments which deduct from balance).
  # `data` is the JSONB blob synced from QBO via QboAccount#fetch_bill_by_id.
  def paid?
    balance = data&.dig("balance")
    return false if balance.nil?
    balance.to_f <= 0
  end

  def total_amount
    (data&.dig("total_amt") || data&.dig("total"))&.to_f
  end

  # True if ANY BillPayment has landed against this bill (full or partial).
  # Destroying a bill with payments orphans the BillPayment(s) in QBO vendor
  # AP, so detach_and_destroy_qbo_bill uses this — not `paid?` alone — to
  # decide whether to refuse.
  def has_payments?
    bal = data&.dig("balance")
    total = total_amount
    return false if bal.nil? || total.nil?
    bal.to_f < total.to_f
  end

  # Remaining unpaid balance on the bill. Reflects partial payments — a bill
  # for $1,778.40 paid down to $0.40 returns 0.4 here. Used by qbo_bound
  # balance computation to mirror QBO's vendor AP exactly.
  #
  # Returns nil (not 0.0) when balance is unknown so callers can distinguish
  # "really $0" from "unknown" — `nil.to_f` collapsing to 0.0 here would
  # silently zero the contributor's qbo_bound balance for a host whose bill
  # data is incomplete.
  def remaining_balance
    raw = data&.dig("balance")
    return nil if raw.nil?
    raw.to_f
  end

  def delete_qbo_bill!
    begin
      qbo_account.delete_bill(qbo_account.fetch_bill_by_id(qbo_id))
    rescue => e
      if e.message.starts_with?("Object Not Found:")
        return nil
      end
      raise e
    end
  end
end
