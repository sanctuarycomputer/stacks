class CreateRunnLeaves < ActiveRecord::Migration[6.1]
  def change
    create_table :runn_leaves do |t|
      t.bigint :runn_person_id, null: false
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.integer :minutes_per_day
      t.datetime :refreshed_at, null: false
      t.jsonb :raw, null: false, default: {}
      t.timestamps
    end
    add_index :runn_leaves, :runn_person_id
  end
end
