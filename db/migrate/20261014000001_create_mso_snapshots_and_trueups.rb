class CreateMsoSnapshotsAndTrueups < ActiveRecord::Migration[6.1]
  def change
    # One row per run of a month's MSO compensation. Everything the run read
    # and everything it produced, so a past month can be reproduced after the
    # roster, the payouts or the Top-N setting have changed.
    create_table :mso_snapshots do |t|
      t.bigint :invoice_pass_id, null: false            # garden3d's pass
      t.bigint :sanctuary_invoice_pass_id, null: false  # the pass whose payouts were read
      t.bigint :created_by_id                           # the admin who ran it
      t.decimal :fee_income, null: false, precision: 12, scale: 2
      # Unrounded, as a string: the benchmark average is a division and a
      # two-decimal column would make a later recomputation differ by a cent.
      t.string :benchmark_average, null: false
      t.integer :configured_n, null: false
      t.integer :counted, null: false
      t.boolean :small_sample, null: false, default: false
      t.decimal :cap_percentage, null: false, precision: 5, scale: 4
      t.decimal :cap, null: false, precision: 16, scale: 6
      t.string :total_calculated, null: false
      t.decimal :total_trueup, null: false, precision: 12, scale: 2
      # The same total, but counting a true-up that already has a QuickBooks
      # bill at its billed amount. More than `cap` means the fee fell after a
      # bill was written.
      t.decimal :total_trueup_as_billed, null: false, precision: 12, scale: 2
      t.jsonb :benchmark_members, null: false, default: []
      t.jsonb :excluded_without_login, null: false, default: []
      t.jsonb :lines, null: false, default: []
      t.jsonb :drift, null: false, default: []
      t.jsonb :reconciliation, null: false, default: {}
      t.datetime :fee_collected_at
      # Set when something after the run means its figures may be wrong.
      # Nothing from an invalidated snapshot is payable; only a new run clears it.
      t.datetime :invalidated_at
      t.text :invalidated_reason
      t.datetime :superseded_at
      t.bigint :superseded_by_id
      t.timestamps
    end
    add_index :mso_snapshots, :invoice_pass_id, name: "index_mso_snapshots_on_invoice_pass_id"
    # At most one snapshot per pass is current.
    add_index :mso_snapshots, :invoice_pass_id, unique: true, where: "superseded_at IS NULL",
      name: "index_mso_snapshots_one_current_per_pass"
    add_index :mso_snapshots, :superseded_by_id, name: "index_mso_snapshots_on_superseded_by_id"
    add_foreign_key :mso_snapshots, :invoice_passes
    add_foreign_key :mso_snapshots, :invoice_passes, column: :sanctuary_invoice_pass_id
    add_foreign_key :mso_snapshots, :mso_snapshots, column: :superseded_by_id

    create_table :mso_trueups do |t|
      t.bigint :ledger_id, null: false
      t.bigint :invoice_pass_id, null: false
      t.bigint :mso_snapshot_id, null: false
      t.bigint :mso_role_period_id, null: false
      t.decimal :amount, null: false, precision: 12, scale: 2
      t.text :description, null: false
      t.datetime :accepted_at
      t.string :qbo_bill_id
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :mso_trueups, :invoice_pass_id, name: "index_mso_trueups_on_invoice_pass_id"
    add_index :mso_trueups, :mso_snapshot_id, name: "index_mso_trueups_on_mso_snapshot_id"
    add_index :mso_trueups, :mso_role_period_id, name: "index_mso_trueups_on_mso_role_period_id"
    add_index :mso_trueups, :qbo_bill_id, name: "index_mso_trueups_on_qbo_bill_id"
    # Partial: with soft deletes a total index would let one deleted row block
    # regeneration forever.
    add_index :mso_trueups, [:ledger_id, :invoice_pass_id], unique: true, where: "deleted_at IS NULL",
      name: "index_mso_trueups_one_live_per_ledger_and_pass"
    add_foreign_key :mso_trueups, :ledgers
    add_foreign_key :mso_trueups, :invoice_passes
    add_foreign_key :mso_trueups, :mso_snapshots
    add_foreign_key :mso_trueups, :mso_role_periods
  end
end
