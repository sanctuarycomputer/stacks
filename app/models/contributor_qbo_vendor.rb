class ContributorQboVendor < ApplicationRecord
  belongs_to :contributor
  belongs_to :qbo_account
  belongs_to :qbo_vendor

  validates :contributor_id, uniqueness: { scope: :qbo_account_id }
  validate :qbo_vendor_belongs_to_same_qbo_account

  private

  # The cached qbo_account_id on the join row must match the vendor's qbo_account.
  # Without this guard, you could store a Garden3D vendor under a Sanctuary mapping
  # and silently push the wrong bill to the wrong QBO company.
  def qbo_vendor_belongs_to_same_qbo_account
    return if qbo_vendor.nil? || qbo_account_id.nil?
    return if qbo_vendor.qbo_account_id == qbo_account_id
    errors.add(:qbo_vendor, "must belong to the same qbo_account as the mapping")
  end
end
