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

    # Raw SQL backfill — `ContributorQboVendor.create!` would fire AR
    # validations that the model evolves over time (a later migration
    # converts qbo_vendor_id to a bigint FK and adds `belongs_to :qbo_vendor`
    # with presence validation). Using SQL keeps the backfill immune to
    # those future model changes.
    execute(<<~SQL)
      INSERT INTO contributor_qbo_vendors (contributor_id, qbo_account_id, qbo_vendor_id, created_at, updated_at)
      SELECT c.id, #{sanctuary_qa.id}, c.qbo_vendor_id, NOW(), NOW()
      FROM contributors c
      WHERE c.qbo_vendor_id IS NOT NULL
    SQL
  end

  def down
    drop_table :contributor_qbo_vendors
  end
end
