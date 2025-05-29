class CreateContributorPayouts < ActiveRecord::Migration[6.1]
  def change
    create_table :contributor_payouts do |t|
      t.references :invoice_tracker, null: false, foreign_key: true
      t.references :contributor, polymorphic: true, null: false
      t.decimal :amount, null: false, default: 0
      t.jsonb :blueprint, null: false, default: {}
      t.timestamps
    end
  end
end