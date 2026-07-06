class CreateBudgets < ActiveRecord::Migration[6.0]
  def change
    create_table :budgets do |t|
      t.string :name, null: false
      t.text :notes
      t.decimal :amount, default: 0, null: false
      t.integer :budget_type, default: 0, null: false

      t.timestamps
    end

    # Add budget relation
    add_reference :pre_spent_budgetary_purchases, :budget, index: true

    PreSpentBudgetaryPurchase.all.each do |psbp|
      psbp.budget = Budget.where(
        name: psbp.spent_at.year.to_s, 
        budget_type: psbp.budget_type
      ).first_or_create
      psbp.save!
    end

    # Drop budget_type from pre_spent_budgetary_purchase
    remove_column :pre_spent_budgetary_purchases, :budget_type

    # Load in all of the pre-spent-budgetary purchases from csv
    require 'csv'
    csv_text = File.read('./lib/assets/index_spend.csv')
    csv = CSV.parse(csv_text, headers: false)
    csv.each do |row|
      last_year_budget = Budget.preload(:pre_spent_budgetary_purchases).where(name: "2022", budget_type: :reinvestment).first_or_create
      last_year_budget.update!(amount: 120_000) if last_year_budget.amount != 120_000

      this_year_budget = Budget.where(name: "2023", budget_type: :reinvestment).first_or_create

      spend = row[2].gsub(/[^\d\.]/, '').to_f

      if (last_year_budget.spent + spend) <= last_year_budget.amount
        PreSpentBudgetaryPurchase.create!(
          note: "[Index Build] #{row[1]}",
          budget: last_year_budget,
          amount: spend,
          spent_at: Date.strptime(row[0], "%m/%d/%Y")
        )
      else
        PreSpentBudgetaryPurchase.create!(
          note: "[Index Build] #{row[1]}",
          budget: this_year_budget,
          amount: spend,
          spent_at: Date.strptime(row[0], "%m/%d/%Y")
        )
      end
    end

  end
end
