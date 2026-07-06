class AddInternalsBudgetMultiplierToProfitSharePasses < ActiveRecord::Migration[6.0]
  def change
    add_column :profit_share_passes, :internals_budget_multiplier, :decimal, default: 0.5
  end
end
