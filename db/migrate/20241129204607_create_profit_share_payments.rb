class CreateProfitSharePayments < ActiveRecord::Migration[6.0]
  def change
    create_table :profit_share_payments do |t|
      t.references :admin_user, null: false, foreign_key: true
      t.references :profit_share_pass, null: false, foreign_key: true

      t.float :tenured_psu_earnt, default: 0
      t.float :project_leadership_psu_earnt, default: 0
      t.float :collective_leadership_psu_earnt, default: 0
      t.float :pre_spent_profit_share, default: 0
      t.float :total_payout, default: 0

      t.timestamps
    end
  end
end
