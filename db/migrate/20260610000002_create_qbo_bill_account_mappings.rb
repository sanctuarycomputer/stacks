class CreateQboBillAccountMappings < ActiveRecord::Migration[6.1]
  def change
    create_table :qbo_bill_account_mappings do |t|
      t.references :enterprise, null: false, foreign_key: true
      t.string :line_item_key, null: false
      # At most one subject column may be set (enforced by check constraint
      # + model validation). Both NULL = entity-level default.
      t.references :project_tracker, null: true, foreign_key: true
      t.references :contributor, null: true, foreign_key: true
      t.string :qbo_chart_account_qbo_id, null: false
      t.timestamps
    end

    # Postgres unique indexes treat NULLs as distinct, so a plain composite
    # unique index would allow duplicate entity-default rows. Three partial
    # indexes cover the three mapping levels.
    add_index :qbo_bill_account_mappings, [:enterprise_id, :line_item_key],
      unique: true,
      where: "project_tracker_id IS NULL AND contributor_id IS NULL",
      name: "idx_qbo_bill_acct_mappings_default"
    add_index :qbo_bill_account_mappings, [:enterprise_id, :line_item_key, :contributor_id],
      unique: true, where: "contributor_id IS NOT NULL",
      name: "idx_qbo_bill_acct_mappings_contributor"
    add_index :qbo_bill_account_mappings, [:enterprise_id, :line_item_key, :project_tracker_id],
      unique: true, where: "project_tracker_id IS NOT NULL",
      name: "idx_qbo_bill_acct_mappings_tracker"

    add_check_constraint :qbo_bill_account_mappings,
      "project_tracker_id IS NULL OR contributor_id IS NULL",
      name: "qbo_bill_acct_mappings_one_subject"
  end
end
