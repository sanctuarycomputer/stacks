class AddControlsToProfitSharePasses < ActiveRecord::Migration[6.0]
  def change
    add_column :profit_share_passes, :payroll_buffer_months, :decimal, default: 2
    add_column :profit_share_passes, :efficiency_cap, :decimal, default: 1.65
  end
end
