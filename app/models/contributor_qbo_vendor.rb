class ContributorQboVendor < ApplicationRecord
  belongs_to :contributor
  belongs_to :qbo_account
  belongs_to :qbo_vendor

  # Lets admin forms (and bulk-link scripts) submit only `qbo_vendor_id` —
  # qbo_account_id is fully determined by the vendor, so deriving it here
  # avoids a cascading dropdown in the UI and a redundant `qbo_account_id`
  # field in every caller.
  before_validation :derive_qbo_account_id_from_vendor

  validates :contributor_id, uniqueness: { scope: :qbo_account_id }
  validate :qbo_vendor_belongs_to_same_qbo_account

  private

  def derive_qbo_account_id_from_vendor
    return if qbo_account_id.present?
    return if qbo_vendor.nil?
    self.qbo_account_id = qbo_vendor.qbo_account_id
  end

  # The cached qbo_account_id on the join row must match the vendor's qbo_account.
  # Without this guard, you could store a Garden3D vendor under a Sanctuary mapping
  # and silently push the wrong bill to the wrong QBO company.
  def qbo_vendor_belongs_to_same_qbo_account
    return if qbo_vendor.nil? || qbo_account_id.nil?
    return if qbo_vendor.qbo_account_id == qbo_account_id
    errors.add(:qbo_vendor, "must belong to the same qbo_account as the mapping")
  end
end
