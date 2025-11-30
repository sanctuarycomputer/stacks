class AddQboBillIdToContributorPayouts < ActiveRecord::Migration[6.1]
  def change
    add_column :contributor_payouts, :qbo_bill_id, :string
    add_index :contributor_payouts, :qbo_bill_id
    add_foreign_key :contributor_payouts, :qbo_bills, column: :qbo_bill_id, primary_key: :qbo_id
  end
end
