class LedgerWithdrawalRequest < ApplicationRecord
  PAID_VIA_DEEL = "deel".freeze
  PAID_VIA_QBO_BILL_PAY = "qbo_bill_pay".freeze
  PAID_VIA_MANUAL = "manual".freeze
  PAID_VIA_VALUES = [PAID_VIA_DEEL, PAID_VIA_QBO_BILL_PAY, PAID_VIA_MANUAL].freeze

  belongs_to :ledger
  belongs_to :cancelled_by, class_name: "AdminUser", optional: true
  belongs_to :deel_invoice_adjustment, optional: true
  has_many :bills,
    class_name: "LedgerWithdrawalRequestBill",
    dependent: :destroy,
    inverse_of: :ledger_withdrawal_request
  has_one :contributor, through: :ledger
  has_one :enterprise, through: :ledger

  accepts_nested_attributes_for :bills

  validates :requested_at, presence: true
  validates :paid_via, inclusion: { in: PAID_VIA_VALUES }, allow_nil: true
  validate :paid_via_set_iff_processed
  validate :cannot_be_processed_and_cancelled

  scope :pending, -> { where(processed_at: nil, cancelled_at: nil) }
  scope :processed, -> { where.not(processed_at: nil) }
  scope :cancelled, -> { where.not(cancelled_at: nil) }

  def pending?
    processed_at.nil? && cancelled_at.nil?
  end

  def processed?
    processed_at.present?
  end

  def cancelled?
    cancelled_at.present?
  end

  # Sum of the amount_snapshot column across every included bill — what the
  # contributor saw on the selection screen when they submitted. Stable
  # against later QBO-side amount edits.
  def total_amount
    bills.sum(:amount_snapshot)
  end

  # Subset of bills whose linked QboBill mirror is marked Paid. Drives the
  # "N / M paid" progress display and the auto-process trigger.
  def paid_bills
    bills.select(&:paid?)
  end

  def all_bills_paid?
    bills.any? && bills.all?(&:paid?)
  end

  # Auto-process: when every Bill in this request is Paid in QBO, flip
  # processed_at without requiring a controller click. Called by the daily
  # QBO sync after the QboBill mirror updates. Idempotent.
  def maybe_auto_process!(paid_via: PAID_VIA_QBO_BILL_PAY)
    return if processed? || cancelled?
    return unless all_bills_paid?
    update!(processed_at: Time.current, paid_via: paid_via)
  end

  private

  def paid_via_set_iff_processed
    if processed_at.present? && paid_via.blank?
      errors.add(:paid_via, "must be set when processed_at is set")
    elsif processed_at.blank? && paid_via.present?
      errors.add(:paid_via, "must be blank when processed_at is blank")
    end
  end

  def cannot_be_processed_and_cancelled
    if processed_at.present? && cancelled_at.present?
      errors.add(:base, "cannot be both processed and cancelled")
    end
  end
end
