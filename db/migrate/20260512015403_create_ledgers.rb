class CreateLedgers < ActiveRecord::Migration[6.1]
  def change
    create_table :ledgers do |t|
      t.references :enterprise, null: false, foreign_key: true
      t.references :contributor, null: false, foreign_key: true
      t.timestamps
    end
    add_index :ledgers, [:enterprise_id, :contributor_id], unique: true
  end
end
