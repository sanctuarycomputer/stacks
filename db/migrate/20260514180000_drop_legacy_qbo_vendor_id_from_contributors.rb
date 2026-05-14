class DropLegacyQboVendorIdFromContributors < ActiveRecord::Migration[6.1]
  # The legacy `contributors.qbo_vendor_id` column was a string FK to
  # `qbo_vendors.qbo_id` from the pre-multi-enterprise era — a single
  # Sanctuary-scoped vendor mapping per contributor. Its job has been
  # taken over by the `contributor_qbo_vendors` join table (one row per
  # contributor × qbo_account), which `Contributor#qbo_vendor_for(qa)`
  # consults from the bill-push pipeline.
  #
  # All read paths and the admin write path were removed in the
  # accompanying app changes; this migration drops the column itself.
  def up
    remove_index :contributors, :qbo_vendor_id if index_exists?(:contributors, :qbo_vendor_id)
    remove_column :contributors, :qbo_vendor_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Restore from DB backup to revert"
  end
end
