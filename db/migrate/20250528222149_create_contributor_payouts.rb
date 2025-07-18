class CreateContributorPayouts < ActiveRecord::Migration[6.1]
  def change
    create_table :contributor_payouts do |t|
      t.references :invoice_tracker, null: false, foreign_key: true
      t.references :forecast_person, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :admin_users }
      t.decimal :amount, null: false, default: 0
      t.jsonb :blueprint, null: false, default: {}
      t.datetime :accepted_at
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :contributor_payouts, :deleted_at
  end
end