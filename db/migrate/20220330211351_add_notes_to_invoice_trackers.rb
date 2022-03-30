class AddNotesToInvoiceTrackers < ActiveRecord::Migration[6.0]
  def change
    add_column :invoice_trackers, :notes, :text
  end
end
