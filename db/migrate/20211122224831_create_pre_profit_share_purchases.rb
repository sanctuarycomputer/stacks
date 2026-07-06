class CreatePreProfitSharePurchases < ActiveRecord::Migration[6.0]
  def change
    create_table :pre_profit_share_purchases do |t|
      t.references :admin_user, null: false, foreign_key: true
      t.decimal :amount
      t.string :note
      t.date :purchased_at

      t.timestamps
    end
  end
end
