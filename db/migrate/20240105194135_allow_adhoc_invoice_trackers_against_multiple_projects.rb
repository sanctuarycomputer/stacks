class AllowAdhocInvoiceTrackersAgainstMultipleProjects < ActiveRecord::Migration[6.0]
  def change
    remove_index :adhoc_invoice_trackers, :qbo_invoice_id
    add_index :adhoc_invoice_trackers, [:qbo_invoice_id, :project_tracker_id], unique: true, name: 'index_adhoc_invoice_trackers_on_qbo_invoice_and_project_tracker'
  end
end
