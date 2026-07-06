class CreateInvoicePasses < ActiveRecord::Migration[6.0]
  def change
    create_table :invoice_passes do |t|
      t.date :start_of_month
      t.datetime :completed_at
      t.jsonb :data

      t.timestamps
    end

    add_index :invoice_passes, :start_of_month, unique: true
  end
end
