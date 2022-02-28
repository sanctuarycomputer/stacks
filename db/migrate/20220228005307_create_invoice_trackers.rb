class CreateInvoiceTrackers < ActiveRecord::Migration[6.0]
  def change
    create_table :invoice_trackers do |t|
      t.references :forecast_client, null: false
      t.references :invoice_pass, null: false, foreign_key: true
      t.string :qbo_invoice_id
      t.jsonb :blueprint

      t.timestamps
    end

    add_index :invoice_trackers,
      [:forecast_client_id, :invoice_pass_id],
      unique: true,
      name: 'idx_invoice_trackers_on_forecast_client_id_and_invoice_pass_id'
  end
end
