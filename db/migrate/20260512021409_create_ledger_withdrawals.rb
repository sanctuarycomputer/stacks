class CreateLedgerWithdrawals < ActiveRecord::Migration[6.1]
  def change
    create_table :ledger_withdrawals do |t|
      t.references :ledger, null: false, foreign_key: true
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.date :effective_on, null: false
      t.text :description
      t.integer :withdrawal_method, null: false
      t.string :withdrawal_status, null: false, default: "pending"
      t.string :deel_contract_id
      t.string :deel_adjustment_id
      t.datetime :accepted_at
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :ledger_withdrawals, :deel_adjustment_id, unique: true, where: "deel_adjustment_id IS NOT NULL"
    add_index :ledger_withdrawals, :withdrawal_status
    add_index :ledger_withdrawals, :deleted_at
  end
end
