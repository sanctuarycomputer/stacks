# Feature gate for ActiveAdmin Deel Withdrawal submission (nested DeelInvoiceAdjustment; see Contributors::SubmitDeelInvoiceAdjustment).
#
# Credentials (per BASE_HOST), either key — same comma-separated / array format:
#   deel:
#     manual_invoice_allowed_emails: "a@x.com, b@y.com"
#     # legacy alias:
#     manual_withdrawal_allowed_emails: "…"
#
# Case-insensitive. Defaults to christian@sanctuary.computer when unset/blank.
class Stacks::DeelWithdrawalAccess
  DEFAULT_EMAILS = ["christian@sanctuary.computer"].freeze

  class << self
    def allowlisted?(email)
      return false if email.blank?

      normalized = email.to_s.strip.downcase
      allowed_emails.include?(normalized)
    end

    def allowed_emails
      d = Stacks::Utils.config[:deel] || {}
      raw = d[:manual_invoice_allowed_emails].presence || d[:manual_withdrawal_allowed_emails]
      list =
        case raw
        when String
          raw.split(",").map(&:strip).reject(&:blank?)
        when Array
          raw.map(&:to_s).map(&:strip).reject(&:blank?)
        else
          []
        end

      (list.presence || DEFAULT_EMAILS).map { |e| e.downcase }
    end
  end
end
