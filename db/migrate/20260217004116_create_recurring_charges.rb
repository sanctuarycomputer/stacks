class CreateRecurringCharges < ActiveRecord::Migration[6.1]
  def change
    create_table :recurring_charges do |t|
      t.references :forecast_client, null: false
      t.decimal :quantity, null: false, default: 0
      t.decimal :unit_price, null: false, default: 0
      t.string :qbo_account_name, null: false, default: ""
      t.string :description, null: false, default: ""
      t.timestamps
    end

    add_index :recurring_charges, [:forecast_client_id, :description], unique: true
  end
end
