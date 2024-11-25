class AddLeadershipPsuPoolToProfitSharePasses < ActiveRecord::Migration[6.0]
  def change
    add_column :profit_share_passes, :leadership_psu_pool_cap, :integer, default: 0
    add_column :profit_share_passes, :leadership_psu_pool_project_role_holders_percentage, :decimal, default: 0
    add_column :collective_roles, :leadership_psu_pool_weighting, :decimal, default: 0
  end
end