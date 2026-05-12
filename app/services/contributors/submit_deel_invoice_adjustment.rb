# Submits a contributor “invoice” to Deel: POST /invoice-adjustments using the org API token (invoice-adjustments:write),
# then persists a Stacks::DeelInvoiceAdjustment row (ledger + Deel status sync).
class Contributors::SubmitDeelInvoiceAdjustment
  class Error < StandardError; end

  attr_reader :contributor, :ledger, :contract_id, :amount, :description, :date_submitted

  # `skip_balance_validation`: when true, skips settled-balance cap (Admin role + checkbox in ActiveAdmin).
  # `ledger`: the ledger the withdrawal is being recorded against. The contract's Deel legal entity
  # must match the ledger's enterprise's Deel legal entity (when the enterprise has one assigned).
  def initialize(contributor:, contract_id:, amount:, description:, date_submitted:, ledger: nil, skip_balance_validation: false)
    @contributor = contributor
    @ledger = ledger || Ledger.find_or_create_for(enterprise: Enterprise.sanctuary, contributor: contributor)
    @contract_id = contract_id.to_s
    @amount = amount
    @description = description.to_s
    @date_submitted = date_submitted
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
      ledger: ledger,
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
  end

  def validate_contract!
    dc = DeelContract.find_by(deel_id: contract_id, deel_person_id: contributor.deel_person_id)
    raise Error, "Choose a Deel contract linked to you in Stacks." unless dc

    unless dc.invoice_adjustments_supported?
      raise Error, "Deel withdrawal is not supported for this contract type (#{dc.deel_contract_type_label}). Pay As You Go and other invoice-cycle contracts support it; classic Milestone contracts without a pay cycle do not."
    end

    enterprise_entity_id = ledger.enterprise.deel_legal_entity_id
    if enterprise_entity_id.present? && dc.deel_legal_entity_id != enterprise_entity_id
      raise Error, "This Deel contract belongs to a different Deel entity than the #{ledger.enterprise.name} ledger. Pick a ledger that matches the contract's entity."
    end
  end

  def validate_inputs!
    raise Error, "Description is required." if description.blank?

    amt = BigDecimal(amount.to_s) rescue nil
    raise Error, "Enter a valid positive amount." if amt.nil? || amt <= 0
  end

  def validate_against_stacks_balance!
    amt = BigDecimal(amount.to_s)
    ledger = contributor.all_items_grouped_by_month(false)
    bal = BigDecimal(contributor.new_deal_balance(ledger)[:balance].to_s)
    raise Error, "Amount cannot exceed your settled Stacks balance (#{bal})." if amt > bal
  end
end
