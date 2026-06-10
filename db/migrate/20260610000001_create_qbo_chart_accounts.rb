class CreateQboChartAccounts < ActiveRecord::Migration[6.1]
  def change
    create_table :qbo_chart_accounts do |t|
      t.string :qbo_id, null: false
      t.bigint :qbo_account_id, null: false
      t.string :name, null: false
      t.string :acct_num
      t.string :classification
      t.string :account_type
      t.boolean :active, null: false, default: true
      t.jsonb :data
    end

    add_index :qbo_chart_accounts, [:qbo_account_id, :qbo_id],
      unique: true, name: "index_qbo_chart_accounts_on_qbo_account_and_qbo_id"
    add_index :qbo_chart_accounts, :qbo_account_id
    add_foreign_key :qbo_chart_accounts, :qbo_accounts
  end
end
