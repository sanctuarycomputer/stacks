class DropProfitabilityPass < ActiveRecord::Migration[6.0]
  def change
    drop_table :profitability_passes
  end
end
