class CreateMsoTrueups < ActiveRecord::Migration[6.1]
  def change
    # An MSO executive's true-up for one month: to a monthly PeriodicReport
    # what a ProfitShare is to a quarterly one. The same columns as
    # profit_shares, plus `description`.
    create_table :mso_trueups do |t|
      t.bigint :periodic_report_id, null: false
      t.bigint :ledger_id, null: false
      t.decimal :amount, null: false, precision: 12, scale: 2
      t.jsonb :blueprint, null: false, default: {}
      t.text :description, null: false
      t.string :qbo_bill_id
      t.datetime :accepted_at
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :mso_trueups, [:periodic_report_id, :ledger_id], unique: true
    add_index :mso_trueups, :periodic_report_id
    add_index :mso_trueups, :ledger_id
    add_index :mso_trueups, :deleted_at
    add_foreign_key :mso_trueups, :periodic_reports
    add_foreign_key :mso_trueups, :ledgers
  end
end
