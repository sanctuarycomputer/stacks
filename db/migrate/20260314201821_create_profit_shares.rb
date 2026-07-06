class CreateProfitShares < ActiveRecord::Migration[6.1]
  def change
    create_table :profit_shares do |t|
      t.references :periodic_report, null: false, foreign_key: true
      t.decimal :amount, null: false
      t.jsonb :blueprint, null: false, default: {}
      t.references :contributor, null: false, foreign_key: true
      t.string :qbo_bill_id
      t.datetime :accepted_at
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :profit_shares, :deleted_at
    add_index :profit_shares, [:periodic_report_id, :contributor_id], unique: true
  end
end
