class ContributorPayout < ApplicationRecord
  acts_as_paranoid

  belongs_to :invoice_tracker
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id"
  belongs_to :created_by, class_name: 'AdminUser'

  validates :amount, presence: true
  validate :contributor_payouts_within_seventy_percent
  validate :only_after_new_deal

  def toggle_acceptance!
    if accepted?
      raise "Cannot unaccept a payout if all payouts have been accepted." if invoice_tracker.contributor_payouts_status == :all_accepted
      update!(accepted_at: nil)
    else
      update!(accepted_at: DateTime.now)
    end
  end

  def accepted?
    accepted_at.present?
  end

  def payable?
    accepted? &&
    (invoice_tracker.status == :paid || (invoice_tracker.allow_early_contributor_payouts_on.present? && invoice_tracker.allow_early_contributor_payouts_on <= Date.today)) &&
    (invoice_tracker.contributor_payouts_status == :all_accepted)
  end

  def only_after_new_deal
    if invoice_tracker.invoice_pass.start_of_month < Stacks::System.singleton_class::NEW_DEAL_START_AT
      errors.add(:base, "Contributor Payouts can only be created for invoices sent after the New Deal began.")
    end
  end

  def status
    if deleted_at.present?
      "deleted"
    elsif blueprint.empty?
      "manual"
    else
      "calculated"
    end
  end

  def contributor_payouts_within_seventy_percent
    cps = invoice_tracker.contributor_payouts.include?(self) ? invoice_tracker.contributor_payouts : [*invoice_tracker.contributor_payouts, self]

    if invoice_tracker.forecast_client.is_internal?
      max_amount = invoice_tracker.qbo_invoice.data.dig("total").to_f
    else
      max_amount = invoice_tracker.qbo_invoice.data.dig("total").to_f * (1 - invoice_tracker.company_treasury_split)
    end

    if cps.sum(&:amount) > (max_amount + 1) # Add a dollar to account for rounding errors
      errors.add(:base, "Contributor Payouts may not exceed #{ActionController::Base.helpers.number_to_currency(max_amount)} (#{100 * (1 - invoice_tracker.company_treasury_split)}% of invoice total).")
    end
  end

  def as_account_lead
    return 0 unless blueprint["AccountLead"].present?
    blueprint["AccountLead"].sum{|l| l["amount"]}
  end

  def as_team_lead
    return 0 unless blueprint["TeamLead"].present?
    blueprint["TeamLead"].sum{|l| l["amount"]}
  end

  def as_individual_contributor
    return 0 unless blueprint["IndividualContributor"].present?
    blueprint["IndividualContributor"].sum{|l| l["amount"]}
  end
end