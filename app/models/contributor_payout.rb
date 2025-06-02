class ContributorPayout < ApplicationRecord
  acts_as_paranoid

  belongs_to :invoice_tracker
  belongs_to :forecast_person, polymorphic: true
  belongs_to :created_by, class_name: 'AdminUser'

  validates :amount, presence: true
  validates :blueprint, presence: true
  validate :contributor_payouts_within_seventy_percent

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
    cps =  invoice_tracker.contributor_payouts.include?(self) ? invoice_tracker.contributor_payouts : [*invoice_tracker.contributor_payouts, self]
    if cps.sum(&:amount) > invoice_tracker.qbo_invoice.data.dig("total").to_f * 0.7
      errors.add(:base, "Contributor Payouts may not exceed 70% of invoice total.")
    end
  end

  def as_account_lead
    blueprint["AccountLead"].sum{|l| l["amount"]}
  end

  def as_team_lead
    blueprint["TeamLead"].sum{|l| l["amount"]}
  end

  def as_individual_contributor
    blueprint["IndividualContributor"].sum{|l| l["amount"]}
  end
end