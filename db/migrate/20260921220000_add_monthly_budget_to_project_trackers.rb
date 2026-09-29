class AddMonthlyBudgetToProjectTrackers < ActiveRecord::Migration[6.1]
  def change
    add_column :project_trackers, :monthly_budget_low_end, :decimal
    add_column :project_trackers, :monthly_budget_high_end, :decimal
  end
end
