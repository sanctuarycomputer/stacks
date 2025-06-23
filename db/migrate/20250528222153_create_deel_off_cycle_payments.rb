class CreateDeelOffCyclePayments < ActiveRecord::Migration[6.0]
  def change
    create_table :deel_off_cycle_payments do |t|
      t.string :deel_id
      t.string :deel_contract_id
      t.jsonb :data
      t.datetime :created_at, null: false
      t.datetime :submitted_at
    end

    add_index :deel_off_cycle_payments, :deel_id, unique: true
    add_index :deel_off_cycle_payments, :deel_contract_id
  end
end