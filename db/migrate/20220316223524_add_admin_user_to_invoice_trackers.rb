class AddAdminUserToInvoiceTrackers < ActiveRecord::Migration[6.0]
  def change
    add_reference :invoice_trackers, :admin_user, null: true, foreign_key: true
  end
end
