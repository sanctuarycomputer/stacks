class CreateDeelContracts < ActiveRecord::Migration[6.0]
  def change
    create_table :deel_contracts do |t|
      t.string :deel_id, null: false
      t.jsonb :data, null: false
      t.string :deel_person_id, null: false
    end

    add_index :deel_contracts, :deel_id, unique: true
  end
end