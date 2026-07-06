class AllowInvoiceTrackerToNullifyQboInvoiceId < ActiveRecord::Migration[6.1]
  def change
    remove_index :qbo_invoices, :qbo_id if index_exists?(:qbo_invoices, :qbo_id)

    add_index :qbo_invoices,
              :qbo_id,
              unique: true,
              where: "qbo_id IS NOT NULL"
  end
end
