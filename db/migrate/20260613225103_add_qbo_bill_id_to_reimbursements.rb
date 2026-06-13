class AddQboBillIdToReimbursements < ActiveRecord::Migration[6.1]
  # Reimbursements now sync as QBO Bills like every other payable host
  # (ContributorPayout, ContributorAdjustment, ProfitShare, Trueup, PayStub),
  # so qbo_bound balance treats them the same: in balance until the QBO bill
  # is marked Paid. Existing accepted reimbursements get backfilled via
  # `bundle exec rake reimbursements:backfill_qbo_bills` — the API push
  # happens out-of-band so the migration stays fast and offline.
  def change
    add_column :reimbursements, :qbo_bill_id, :string
    add_index  :reimbursements, :qbo_bill_id
  end
end
