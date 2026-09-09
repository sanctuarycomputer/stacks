class AddBillingModelToProjectTrackers < ActiveRecord::Migration[6.1]
  def up
    add_column :project_trackers, :billing_model, :string, null: false, default: "new_deal_v1"

    execute <<~SQL
      UPDATE project_trackers SET billing_model = 'new_deal_v1' WHERE company_treasury_split = 0.30;
      UPDATE project_trackers SET billing_model = 'new_deal_v2' WHERE company_treasury_split = 0.33;
    SQL

    unmapped = select_values(<<~SQL)
      SELECT id FROM project_trackers
      WHERE company_treasury_split IS NOT NULL
        AND company_treasury_split NOT IN (0.30, 0.33)
    SQL
    if unmapped.any?
      raise ActiveRecord::MigrationError,
        "project_trackers #{unmapped.join(', ')} have a company_treasury_split that maps to no billing model; " \
        "set them to 0.30 or 0.33 before migrating"
    end

    remove_check_constraint :project_trackers, name: "check_company_treasury_split_range"
    remove_column :project_trackers, :company_treasury_split
  end

  def down
    add_column :project_trackers, :company_treasury_split, :decimal, default: 0.3
    add_check_constraint :project_trackers, "company_treasury_split >= 0 AND company_treasury_split <= 1", name: "check_company_treasury_split_range"
    execute <<~SQL
      UPDATE project_trackers SET company_treasury_split = 0.33 WHERE billing_model = 'new_deal_v2';
      UPDATE project_trackers SET company_treasury_split = 0.30 WHERE billing_model = 'new_deal_v1';
    SQL
    remove_column :project_trackers, :billing_model
  end
end
