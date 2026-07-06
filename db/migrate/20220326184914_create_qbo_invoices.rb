class CreateQboInvoices < ActiveRecord::Migration[6.0]
  def change
    create_table :qbo_invoices do |t|
      t.string :qbo_id, null: false
      t.jsonb :data
    end

    add_index :qbo_invoices, :qbo_id, unique: true
  end
end
