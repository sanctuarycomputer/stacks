class CreateQboPurchaseLineItems < ActiveRecord::Migration[6.0]
  def change
    create_table :qbo_purchase_line_items, id: :string do |t|
      t.date :txn_date
      t.string :qbo_purchase_id
      t.string :description
      t.float :amount
    end

    add_index :qbo_purchase_line_items, :id, unique: true
  end
end
