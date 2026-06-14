class AddQboBillIdToReimbursements < ActiveRecord::Migration[6.1]
  # Reimbursements sync as QBO Bills like every other payable host
  # (ContributorPayout, ContributorAdjustment, ProfitShare, Trueup, PayStub).
  # Existing accepted reimbursements get backfilled out-of-band via
  # `bundle exec rake reimbursements:backfill_qbo_bills` so the migration
  # stays fast and offline.
  def change
    add_column :reimbursements, :qbo_bill_id, :string
    add_index  :reimbursements, :qbo_bill_id
  end
end
