class DeelContract < ApplicationRecord
  self.primary_key = "deel_id"
  validates :deel_id, presence: true, uniqueness: true
  validates :deel_person_id, presence: true

  belongs_to :deel_person, class_name: "DeelPerson", foreign_key: "deel_person_id"

  # From Deel’s synced contract JSON (`GET /contracts` → stored in `data`).
  PAY_AS_YOU_GO_TYPES = %w[
    pay_as_you_go_time_based
    payg_milestones
    payg_tasks
  ].freeze

  # Deel: “Milestone” contracts without pay cycles cannot take invoice adjustments (help center).
  CONTRACT_TYPES_WITHOUT_INVOICE_ADJUSTMENTS = %w[milestones].freeze

  def deel_contract_type
    data.is_a?(Hash) ? data["type"].to_s : ""
  end

  def pay_as_you_go_family?
    PAY_AS_YOU_GO_TYPES.include?(deel_contract_type)
  end

  def invoice_adjustments_supported?
    return true if deel_contract_type.blank?

    !CONTRACT_TYPES_WITHOUT_INVOICE_ADJUSTMENTS.include?(deel_contract_type)
  end

  def deel_contract_type_label
    case deel_contract_type
    when "pay_as_you_go_time_based" then "Pay As You Go"
    when "payg_milestones" then "Pay As You Go (milestones)"
    when "payg_tasks" then "Pay As You Go (tasks)"
    when "ongoing_time_based" then "Fixed / time-based"
    when "milestones" then "Milestone"
    else deel_contract_type.presence || "unknown"
    end
  end

  def display_name_for_deel_invoice_select
    title = data.is_a?(Hash) ? data["title"].presence : nil
    kind = pay_as_you_go_family? ? "Pay As You Go" : deel_contract_type_label
    "#{title || 'Contract'} — #{kind} — #{deel_id.to_s[0, 10]}…"
  end

  # Pay-as-you-go contracts first, then by label (matches Deel Withdrawal ActiveAdmin form).
  def self.sorted_for_balance_withdrawal_select(deel_person_id)
    return [] if deel_person_id.blank?

    where(deel_person_id: deel_person_id).to_a.sort_by do |dc|
      [dc.pay_as_you_go_family? ? 0 : 1, dc.display_name_for_deel_invoice_select.to_s.downcase]
    end
  end
end