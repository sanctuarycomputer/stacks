class CreateTrueups < ActiveRecord::Migration[6.1]
  def change
    create_table :trueups do |t|
      t.references :invoice_pass, null: false, foreign_key: true
      t.references :forecast_person, null: false
      t.decimal :amount, null: false, default: 0
      t.text :description
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
