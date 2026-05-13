class CreateContributorQboVendors < ActiveRecord::Migration[6.1]
  def up
    create_table :contributor_qbo_vendors do |t|
      t.references :contributor, null: false, foreign_key: true
      t.references :qbo_account, null: false, foreign_key: true
      # qbo_vendor_id is a STRING that references qbo_vendors.qbo_id within the scope of qbo_account_id.
      # We don't FK to qbo_vendors directly because qbo_vendors.qbo_id is no longer globally unique
      # (it's composite-unique with qbo_account_id after the prior scoping migration).
      t.string :qbo_vendor_id, null: false
      t.timestamps
    end
    add_index :contributor_qbo_vendors, [:contributor_id, :qbo_account_id], unique: true,
      name: "index_cqv_unique_per_contributor_account"

    # Backfill from existing contributors.qbo_vendor_id (Sanctuary's vendor id for each contributor).
    sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    sanctuary_qa = sanctuary.qbo_account
    raise "Sanctuary has no qbo_account; cannot backfill" if sanctuary_qa.nil?

    Contributor.where.not(qbo_vendor_id: nil).find_each do |c|
      ContributorQboVendor.create!(
        contributor: c,
        qbo_account: sanctuary_qa,
        qbo_vendor_id: c.qbo_vendor_id,
      )
    end
  end

  def down
    drop_table :contributor_qbo_vendors
  end
end
