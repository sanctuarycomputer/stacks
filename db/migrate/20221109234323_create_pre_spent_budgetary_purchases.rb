class CreatePreSpentBudgetaryPurchases < ActiveRecord::Migration[6.0]
  def change
    create_table :pre_spent_budgetary_purchases do |t|
      t.integer :budget_type, default: 0, null: false
      t.decimal :amount, null: false
      t.string :note
      t.date :spent_at, null: false

      t.timestamps
    end
  end
end
