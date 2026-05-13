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

    # Some contributors may have a stale qbo_vendor_id pointing at a QboVendor
    # row that's since been deleted (e.g., the vendor was archived in QBO and
    # purged from qbo_vendors by a sync). Those mappings can't be carried into
    # the bigint-FK world — they have no qbo_vendors.id to point at. Drop them
    # explicitly and log what we drop so the admin can investigate / re-link
    # via the contributor admin form.
    orphans = ActiveRecord::Base.connection.execute(<<~SQL).to_a
      SELECT cqv.id, cqv.contributor_id, cqv.qbo_account_id, cqv.qbo_vendor_id
      FROM contributor_qbo_vendors cqv
      WHERE cqv.qbo_vendor_pk_id IS NULL
    SQL
    if orphans.any?
      summary = orphans.first(10).map { |r| "contributor_id=#{r["contributor_id"]} qbo_vendor_id=#{r["qbo_vendor_id"]}" }.join("; ")
      suffix = orphans.size > 10 ? " (+#{orphans.size - 10} more)" : ""
      say_with_time "Dropping #{orphans.size} orphan contributor_qbo_vendors row(s) with no matching qbo_vendors row: #{summary}#{suffix}" do
        execute "DELETE FROM contributor_qbo_vendors WHERE qbo_vendor_pk_id IS NULL"
      end
      # Also clear the legacy contributors.qbo_vendor_id for those rows so the
      # data is consistent — the value is now a dangling pointer.
      orphan_contributor_ids = orphans.map { |r| r["contributor_id"] }.join(",")
      execute "UPDATE contributors SET qbo_vendor_id = NULL WHERE id IN (#{orphan_contributor_ids})"
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
