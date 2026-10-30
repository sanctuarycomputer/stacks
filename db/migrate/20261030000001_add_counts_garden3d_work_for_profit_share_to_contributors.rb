class AddCountsGarden3dWorkForProfitShareToContributors < ActiveRecord::Migration[6.1]
  def change
    # Profit share counts only Sanctuary-billed work. Admins tick this for the
    # few people whose garden3d-billed work is Sanctuary service in practice.
    add_column :contributors, :counts_garden3d_work_for_profit_share, :boolean, default: false, null: false
  end
end
