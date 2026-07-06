class CreateGiftedProfitShares < ActiveRecord::Migration[6.0]
  def change
    create_table :gifted_profit_shares do |t|
      t.references :admin_user, null: false, foreign_key: true
      t.decimal :amount
      t.string :reason

      t.timestamps
    end
  end
end
