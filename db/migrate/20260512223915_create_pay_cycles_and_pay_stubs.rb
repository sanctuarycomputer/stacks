class CreatePayCyclesAndPayStubs < ActiveRecord::Migration[6.1]
  def change
    create_table :pay_cycles do |t|
      t.references :enterprise, null: false, foreign_key: true
      t.date :starts_at, null: false
      t.date :ends_at, null: false
      t.references :created_by, foreign_key: { to_table: :admin_users }
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :pay_cycles, [:enterprise_id, :starts_at, :ends_at], unique: true, name: "index_pay_cycles_unique_window"
    add_index :pay_cycles, :deleted_at

    create_table :pay_stubs do |t|
      t.references :pay_cycle, null: false, foreign_key: true
      t.references :ledger, null: false, foreign_key: true
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.jsonb :blueprint, null: false, default: {}
      t.datetime :accepted_at
      t.references :accepted_by, foreign_key: { to_table: :admin_users }
      t.string :qbo_bill_id
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :pay_stubs, [:pay_cycle_id, :ledger_id], unique: true, name: "index_pay_stubs_unique_per_cycle_ledger"
    add_index :pay_stubs, :deleted_at
    add_index :pay_stubs, :qbo_bill_id, unique: true, where: "qbo_bill_id IS NOT NULL"

    add_column :enterprises, :pay_cycle_cadence, :string
  end
end
