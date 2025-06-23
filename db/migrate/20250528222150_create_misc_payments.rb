class CreateMiscPayments < ActiveRecord::Migration[6.0]
  def change
    create_table :misc_payments do |t|
      t.integer :forecast_person_id, null: false
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.text :remittance
      t.datetime :deleted_at
      t.date :paid_at

      t.timestamps
    end

    add_index :misc_payments, :forecast_person_id
    add_index :misc_payments, :deleted_at
  end
end