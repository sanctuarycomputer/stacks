class CreateQboVendors < ActiveRecord::Migration[6.1]
  def change
    create_table :qbo_vendors do |t|
      t.string :qbo_id, null: false
      t.jsonb :data
    end

    add_index :qbo_vendors, :qbo_id, unique: true
  end
end
