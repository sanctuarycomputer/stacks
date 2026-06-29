class DeelPerson < ApplicationRecord
  self.primary_key = "deel_id"
  validates :deel_id, presence: true, uniqueness: true
  has_many :deel_contracts, class_name: "DeelContract", foreign_key: "deel_person_id"

  def display_name
    data["full_name"]
  end

  # Deel's /people API stores the country code inside `data["addresses"]`,
  # NOT at `data["country"]`. PeriodicReport already reads from this path
  # for cost-of-living lookups; this helper centralizes the shape so other
  # callers (Ledger.payment_methods_for, etc.) don't repeat the wrong-shape
  # `data["country"]` mistake.
  def country
    return nil unless data.is_a?(Hash)
    addr = data["addresses"]
    addr.first.dig("country") if addr.is_a?(Array) && addr.first.is_a?(Hash)
  end
end