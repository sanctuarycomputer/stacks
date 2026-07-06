class AddReportUrlToPeriodicReports < ActiveRecord::Migration[6.1]
  def change
    add_column :periodic_reports, :report_url, :string
  end
end
