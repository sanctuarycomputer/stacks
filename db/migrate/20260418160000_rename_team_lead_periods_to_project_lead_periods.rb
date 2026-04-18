class RenameTeamLeadPeriodsToProjectLeadPeriods < ActiveRecord::Migration[6.1]
  def change
    rename_table :team_lead_periods, :project_lead_periods
  end
end
