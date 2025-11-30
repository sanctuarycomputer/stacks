class CreateQboBills < ActiveRecord::Migration[6.1]
  def change
    create_table :qbo_bills do |t|
      t.string :qbo_id, null: false
      t.jsonb :data
      t.string :qbo_vendor_id, null: false
    end

    add_index :qbo_bills, :qbo_vendor_id
    add_index :qbo_bills, :qbo_id, unique: true
  end
end
