class AddQboBillIdToTrueups < ActiveRecord::Migration[6.1]
  def change
    add_column :trueups, :qbo_bill_id, :string
    add_index :trueups, :qbo_bill_id
    add_foreign_key :trueups, :qbo_bills, column: :qbo_bill_id, primary_key: :qbo_id
  end
end
