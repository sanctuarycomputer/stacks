class PayStub < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include SyncsAsQboBill

  before_destroy :detach_and_destroy_qbo_bill

  belongs_to :pay_cycle
  belongs_to :accepted_by, class_name: "AdminUser", optional: true

  validates :amount, presence: true
  validates :blueprint, presence: true
  validates :pay_cycle_id, uniqueness: { scope: :ledger_id }
  validate :blueprint_has_lines_array
  validate :amount_matches_blueprint_sum
  validate :ledger_enterprise_matches_pay_cycle_enterprise
  validate :acceptance_pair_consistent

  def accepted?
    accepted_at.present?
  end

  # Same pattern as ContributorPayout#toggle_acceptance! but tracks accepted_by_id.
  # Caller must pass the AdminUser doing the toggle (controllers pass current_admin_user).
  def toggle_acceptance!(by:)
    if accepted?
      raise "Cannot unaccept a pay stub once all stubs in the cycle are accepted." if pay_cycle.stubs_status == :all_accepted
      update!(accepted_at: nil, accepted_by_id: nil)
    else
      update!(accepted_at: DateTime.now, accepted_by_id: by.id)
    end
  end

  # LedgerItem contract overrides.
  # A stub is payable iff:
  #   1. The contributor accepted their own stub
  #   2. Every OTHER stub in the cycle is also accepted (implicit lock — same
  #      logic as ContributorPayout-on-InvoiceTracker)
  #   3. An enterprise admin has approved the cycle as a whole
  #
  # Condition (3) is new for pay cycles. The existing invoice-tracker flow
  # doesn't have an analogue because client invoices are externally enforced
  # by being client-facing; internal pay cycles need a human approver.
  def payable?
    accepted? && pay_cycle.stubs_status == :all_accepted && pay_cycle.approved?
  end

  def effective_on_for_display
    pay_cycle.ends_at
  end

  # SyncsAsQboBill contract.
  def bill_txn_date
    pay_cycle.ends_at
  end

  def bill_description
    "https://stacks.garden3d.net/admin/pay_cycles/#{pay_cycle_id}/pay_stubs/#{id}"
  end

  def bill_doc_number_code
    "SB" # "[S]tu[B]" — distinct from ProfitShare's "PS"
  end

  def find_qbo_account!(qbo_accounts = nil)
    qa = qbo_account_for_bill
    raise "Enterprise #{enterprise&.name.inspect} has no connected QboAccount" if qa.nil?
    qbo_accounts ||= qa.fetch_all_accounts
    account = qbo_accounts.find { |a| a.name == "Facilities Management Salaries" }
    raise "No 'Facilities Management Salaries' account found in QuickBooks for #{enterprise&.name}" unless account.present?
    [account, nil]
  end

  def bill_line_items(qbo_accounts)
    account, _ = find_qbo_account!(qbo_accounts)
    lines = blueprint["lines"] || []
    grouped = lines.group_by { |l| l["forecast_project"] }

    fp_ids = grouped.keys.compact
    projects_by_id = ForecastProject.where(forecast_id: fp_ids).index_by(&:forecast_id)

    grouped.map do |fp_id, group|
      fp = projects_by_id[fp_id]
      project_name = fp&.display_name || "Forecast project ##{fp_id}"
      hours = group.sum { |l| l["hours"].to_f }.round(2)
      line_amount = group.sum { |l| l["amount"].to_f }.round(2)

      line = Quickbooks::Model::BillLineItem.new(
        description: "#{project_name} — #{hours}h",
        amount: line_amount,
      )
      line.account_based_expense_item! do |detail|
        detail.account_ref = Quickbooks::Model::BaseReference.new(account.id)
      end
      line
    end
  end

  private

  def blueprint_has_lines_array
    return if blueprint.is_a?(Hash) && blueprint["lines"].is_a?(Array)
    errors.add(:blueprint, "must contain a 'lines' array")
  end

  def amount_matches_blueprint_sum
    return unless blueprint.is_a?(Hash) && blueprint["lines"].is_a?(Array)
    sum = blueprint["lines"].sum { |l| l["amount"].to_f }.round(2)
    return if (amount.to_f.round(2) - sum).abs < 0.01
    errors.add(:amount, "must equal the sum of blueprint['lines'] amounts")
  end

  def ledger_enterprise_matches_pay_cycle_enterprise
    return if ledger.blank? || pay_cycle.blank?
    return if ledger.enterprise_id == pay_cycle.enterprise_id
    errors.add(:ledger, "must belong to the same enterprise as the pay_cycle")
  end

  def acceptance_pair_consistent
    if accepted_at.present? && accepted_by_id.blank?
      errors.add(:accepted_by_id, "must be set when accepted_at is set")
    elsif accepted_at.blank? && accepted_by_id.present?
      errors.add(:accepted_at, "must be set when accepted_by_id is set")
    end
  end
end
