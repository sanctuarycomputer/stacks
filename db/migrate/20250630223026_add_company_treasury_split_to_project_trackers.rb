class AddCompanyTreasurySplitToProjectTrackers < ActiveRecord::Migration[6.1]
  def change
    add_column :project_trackers, :company_treasury_split, :decimal, default: 0.3
    add_check_constraint :project_trackers, "company_treasury_split >= 0 AND company_treasury_split <= 1", name: "check_company_treasury_split_range"
  end
end
