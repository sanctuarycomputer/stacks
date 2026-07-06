class CreateContributorAdjustments < ActiveRecord::Migration[6.1]
  def change
    create_table :contributor_adjustments do |t|
      t.references :contributor, null: false, foreign_key: true
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.date :effective_on, null: false
      t.string :qbo_invoice_id
      t.text :description
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :contributor_adjustments, :deleted_at
    add_index :contributor_adjustments, :qbo_invoice_id
  end
end
