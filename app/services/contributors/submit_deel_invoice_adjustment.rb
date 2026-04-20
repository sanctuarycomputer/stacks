# Submits a contributor “invoice” to Deel: POST /invoice-adjustments using the org API token (invoice-adjustments:write),
# then persists a Stacks::DeelInvoiceAdjustment row (ledger + Deel status sync).
class Contributors::SubmitDeelInvoiceAdjustment
  class Error < StandardError; end

  attr_reader :contributor, :contract_id, :amount, :description, :date_submitted

  # `bypass_team_allowlist`: when true (staff `is_admin?`), skips DeelWithdrawalAccess on the linked team member so ops can submit.
  # `skip_balance_validation`: when true, skips settled-balance cap (Admin role + checkbox in ActiveAdmin).
  def initialize(contributor:, contract_id:, amount:, description:, date_submitted:, bypass_team_allowlist: false, skip_balance_validation: false)
    @contributor = contributor
    @contract_id = contract_id.to_s
    @amount = amount
    @description = description.to_s
    @date_submitted = date_submitted
    @bypass_team_allowlist = bypass_team_allowlist
    @skip_balance_validation = skip_balance_validation
  end

  def self.call(**kwargs)
    new(**kwargs).call
  end

  def call
    validate_access!
    validate_contract!
    validate_inputs!
    validate_against_stacks_balance! unless @skip_balance_validation

    parsed = Stacks::Deel.create_invoice_adjustment!(
      amount: BigDecimal(amount.to_s),
      contract_id: contract_id,
      description: description,
      date_submitted: date_submitted,
    )

    DeelInvoiceAdjustment.create_from_deel_response!(
      contributor: contributor,
      deel_contract_id: contract_id,
      amount: BigDecimal(amount.to_s),
      description: description,
      date_submitted: date_submitted,
      parsed_response: parsed,
    )
  rescue Stacks::Deel::ApiError => e
    raise Error, e.message
  rescue ArgumentError => e
    raise Error, e.message
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.join(", ")
  end

  private

  def validate_access!
    raise Error, "Deel profile is not linked for this contributor." if contributor.deel_person_id.blank?

    linked_admin = contributor.forecast_person&.admin_user
    raise Error, "No team member is linked to this contributor." unless linked_admin

    unless @bypass_team_allowlist
      unless Stacks::DeelWithdrawalAccess.allowlisted?(linked_admin.email)
        raise Error, "Deel withdrawal is not enabled for the linked team member (Deel allowlist)."
      end
    end
  end

  def validate_contract!
    dc = DeelContract.find_by(deel_id: contract_id, deel_person_id: contributor.deel_person_id)
    raise Error, "Choose a Deel contract linked to you in Stacks." unless dc

    unless dc.invoice_adjustments_supported?
      raise Error, "Deel withdrawal is not supported for this contract type (#{dc.deel_contract_type_label}). Pay As You Go and other invoice-cycle contracts support it; classic Milestone contracts without a pay cycle do not."
    end
  end

  def validate_inputs!
    raise Error, "Description is required." if description.blank?

    amt = BigDecimal(amount.to_s) rescue nil
    raise Error, "Enter a valid positive amount." if amt.nil? || amt <= 0
  end

  def validate_against_stacks_balance!
    amt = BigDecimal(amount.to_s)
    ledger = contributor.new_deal_ledger_items(false)
    bal = BigDecimal(contributor.new_deal_balance(ledger)[:balance].to_s)
    raise Error, "Amount cannot exceed your settled Stacks balance (#{bal})." if amt > bal
  end
end
