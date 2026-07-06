class DropUnusedTables < ActiveRecord::Migration[6.0]
  def change
    drop_table :budgets
    drop_table :qbo_purchase_line_items
    drop_table :expense_groups
    drop_table :pre_spent_budgetary_purchases
    drop_table :social_properties
  end
end
