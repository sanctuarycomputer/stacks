class LedgerWithdrawal < ApplicationRecord
  acts_as_paranoid
  include LedgerItem

  enum withdrawal_method: { deel_contract: 0 }

  PAYABLE_STATUSES = %w[approved paid].freeze

  validates :amount, presence: true, numericality: true
  validates :effective_on, presence: true
  validates :withdrawal_method, presence: true
  validates :withdrawal_status, presence: true

  def signed_amount
    -amount
  end

  def payable?
    PAYABLE_STATUSES.include?(withdrawal_status.to_s)
  end

  def effective_on_for_display
    effective_on
  end
end
