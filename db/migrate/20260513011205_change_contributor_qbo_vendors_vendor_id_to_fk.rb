class ChangeContributorQboVendorsVendorIdToFk < ActiveRecord::Migration[6.1]
  # Until now, contributor_qbo_vendors.qbo_vendor_id was a STRING column
  # mirroring qbo_vendors.qbo_id. That mirrored the legacy
  # contributors.qbo_vendor_id pattern but made the association awkward —
  # `has_many :qbo_vendors, through: :contributor_qbo_vendors` couldn't be
  # used cleanly because the FK didn't reference the AR primary key.
  #
  # This migration swaps the string column for a proper bigint FK to
  # qbo_vendors.id so the join table is a real Rails join: Contributor
  # has_many :qbo_vendors, through: :contributor_qbo_vendors.
  def up
    # Add a new bigint column to hold the proper FK
    add_column :contributor_qbo_vendors, :qbo_vendor_pk_id, :bigint

    # Backfill: translate each row's (qbo_account_id, qbo_vendor_id-string) → qbo_vendors.id
    execute(<<~SQL)
      UPDATE contributor_qbo_vendors cqv
      SET qbo_vendor_pk_id = qv.id
      FROM qbo_vendors qv
      WHERE qv.qbo_account_id = cqv.qbo_account_id
        AND qv.qbo_id = cqv.qbo_vendor_id
    SQL

    orphans = ActiveRecord::Base.connection.execute(
      "SELECT COUNT(*) FROM contributor_qbo_vendors WHERE qbo_vendor_pk_id IS NULL"
    ).first["count"].to_i
    if orphans > 0
      raise "Backfill failed: #{orphans} contributor_qbo_vendors rows have no matching qbo_vendors row. " \
            "Run Stacks::Quickbooks.sync_all_vendors! first, then retry."
    end

    # Drop the old string column
    remove_column :contributor_qbo_vendors, :qbo_vendor_id

    # Rename the bigint column to take the conventional name
    rename_column :contributor_qbo_vendors, :qbo_vendor_pk_id, :qbo_vendor_id
    change_column_null :contributor_qbo_vendors, :qbo_vendor_id, false

    # FK constraint + index for the join lookup
    add_foreign_key :contributor_qbo_vendors, :qbo_vendors
    add_index :contributor_qbo_vendors, :qbo_vendor_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Restore from DB backup to revert"
  end
end
