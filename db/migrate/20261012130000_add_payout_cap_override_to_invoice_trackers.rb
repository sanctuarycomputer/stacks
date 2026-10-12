class AddPayoutCapOverrideToInvoiceTrackers < ActiveRecord::Migration[6.1]
  def change
    add_reference :invoice_trackers, :payout_cap_override_by, foreign_key: { to_table: :admin_users, on_delete: :nullify }, null: true
    add_column :invoice_trackers, :payout_cap_override_at, :datetime
    add_column :invoice_trackers, :payout_cap_override_reason, :text
    add_column :invoice_trackers, :payout_cap_override_payout_percentage, :decimal
    add_column :invoice_trackers, :payout_cap_override_cap_percentage, :decimal
  end
end
