class CreateDeelInvoiceAdjustments < ActiveRecord::Migration[6.1]
  def change
    create_table :deel_invoice_adjustments do |t|
      t.references :contributor, null: false, foreign_key: true
      t.string :deel_contract_id, null: false
      t.string :deel_adjustment_id, null: false
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.text :description, null: false
      t.date :date_submitted, null: false
      t.string :deel_status, null: false, default: "pending"
      t.datetime :synced_at
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :deel_invoice_adjustments, :deel_adjustment_id, unique: true
    add_index :deel_invoice_adjustments, :deel_contract_id
    add_index :deel_invoice_adjustments, :deleted_at

    add_foreign_key :deel_invoice_adjustments, :deel_contracts, column: :deel_contract_id, primary_key: :deel_id
  end
end
