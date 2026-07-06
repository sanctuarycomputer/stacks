class RenameOldDealLeadPeriodTables < ActiveRecord::Migration[6.1]
  def change
    rename_table :project_lead_periods, :old_deal_project_lead_periods
    rename_table :creative_lead_periods, :old_deal_creative_lead_periods
    rename_table :technical_lead_periods, :old_deal_technical_lead_periods
    rename_table :project_safety_representative_periods, :old_deal_project_safety_representative_periods
  end
end
