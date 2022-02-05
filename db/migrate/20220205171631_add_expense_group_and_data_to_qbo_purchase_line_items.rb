class AddExpenseGroupAndDataToQboPurchaseLineItems < ActiveRecord::Migration[6.0]
  def change
    add_reference :qbo_purchase_line_items, :expense_group, foreign_key: true
    add_column :qbo_purchase_line_items, :data, :jsonb, default: {}
  end
end
