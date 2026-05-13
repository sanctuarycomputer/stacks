class ContributorQboVendor < ApplicationRecord
  belongs_to :contributor
  belongs_to :qbo_account

  validates :qbo_vendor_id, presence: true
  validates :contributor_id, uniqueness: { scope: :qbo_account_id }
end
