class DeelInvoiceAdjustment < ApplicationRecord
  acts_as_paranoid

  # Form-only (ActiveAdmin): not persisted. Server must still verify initiator has admin role.
  attr_accessor :allow_ledger_overdraw

  belongs_to :contributor
  belongs_to :deel_contract, foreign_key: :deel_contract_id, primary_key: :deel_id

  validates :deel_adjustment_id, presence: true, uniqueness: true
  validates :amount, presence: true, numericality: { greater_than_or_equal_to: 0.01 }
  validates :description, presence: true
  validates :date_submitted, presence: true
  validates :deel_status, presence: true

  NON_DEDUCTING_STATUSES = %w[rejected cancelled canceled declined void voided].freeze
  APPROVED_LEDGER_STATUSES = %w[approved paid].freeze

  def deducts_balance?
    return false if deleted_at.present?

    !NON_DEDUCTING_STATUSES.include?(deel_status.to_s.downcase.strip)
  end

  def deel_status_key
    deel_status.to_s.downcase.strip
  end

  # ActiveAdmin ledger pill CSS (`active_admin.scss` .pill): green for approved, orange for in-flight, purple for void/cancel, etc.
  def ledger_status_pill_class
    return "deleted" if deleted_at.present?
    return "voided" if NON_DEDUCTING_STATUSES.include?(deel_status_key)
    return "accepted" if APPROVED_LEDGER_STATUSES.include?(deel_status_key)

    "pending"
  end

  # Strikethrough amount when the row is removed in Stacks or terminal void/reject in Deel.
  def ledger_amount_strikethrough?
    deleted_at.present? || NON_DEDUCTING_STATUSES.include?(deel_status_key)
  end

  # Normalized `data` object from Deel JSON (wrapped or top-level).
  def self.payload_data_hash(parsed)
    return {} unless parsed.is_a?(Hash)

    d = parsed["data"]
    d.is_a?(Hash) ? d : parsed
  end

  def self.deel_id_and_status_from_api_payload(parsed)
    data = payload_data_hash(parsed)

    id =
      data["id"] ||
      data["adjustment_id"] ||
      data.dig("attributes", "id")

    raw_status = data["status"] || data["state"] || data.dig("attributes", "status")
    status = raw_status.to_s.downcase.strip.presence || "pending"

    [id.to_s.presence, status]
  end

  # Fields Deel returns for GET /invoice-adjustments/:id (and often for create). Used to keep Stacks rows in sync as a cache.
  def self.attributes_from_deel_api_payload(parsed)
    data = payload_data_hash(parsed)
    return { deel_status: "pending" } if data.blank?

    raw_status = data["status"] || data["state"] || data.dig("attributes", "status")
    deel_status = raw_status.to_s.downcase.strip.presence || "pending"

    attrs = { deel_status: deel_status }

    raw_amount = data["amount"] || data["total_amount"]
    if raw_amount.present?
      attrs[:amount] = BigDecimal(raw_amount.to_s)
    end

    if data["description"].present?
      attrs[:description] = data["description"].to_s
    end

    date_raw = data["date_submitted"].presence || data["submitted_date"].presence
    if date_raw.present?
      attrs[:date_submitted] = date_raw.is_a?(Date) ? date_raw : Date.parse(date_raw.to_s)
    end

    attrs
  end

  def self.create_from_deel_response!(contributor:, deel_contract_id:, amount:, description:, date_submitted:, parsed_response:)
    deel_adjustment_id, _status = deel_id_and_status_from_api_payload(parsed_response)
    raise ArgumentError, "Deel response did not include an adjustment id." if deel_adjustment_id.blank?

    from_api = attributes_from_deel_api_payload(parsed_response)

    date =
      from_api[:date_submitted] ||
        case date_submitted
        when Date
          date_submitted
        when Time, ActiveSupport::TimeWithZone
          date_submitted.to_date
        else
          Date.parse(date_submitted.to_s)
        end

    create!(
      {
        contributor: contributor,
        deel_contract_id: deel_contract_id.to_s,
        deel_adjustment_id: deel_adjustment_id,
        amount: from_api[:amount] || BigDecimal(amount.to_s),
        description: from_api[:description].presence || description.to_s,
        date_submitted: date,
        deel_status: from_api[:deel_status].presence || _status,
        synced_at: Time.current,
      },
    )
  end
end
