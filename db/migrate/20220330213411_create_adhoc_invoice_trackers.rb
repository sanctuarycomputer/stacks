class CreateAdhocInvoiceTrackers < ActiveRecord::Migration[6.0]
  def change
    create_table :adhoc_invoice_trackers do |t|
      t.string :qbo_invoice_id, null: false
      t.references :project_tracker, null: false, foreign_key: true

      t.timestamps
    end

    add_index :adhoc_invoice_trackers, :qbo_invoice_id, unique: true
  end
end
