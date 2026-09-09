class CreateRunnPeople < ActiveRecord::Migration[6.1]
  def change
    create_table :runn_people do |t|
      t.bigint :runn_id, null: false
      t.string :first_name
      t.string :last_name
      t.string :email
      t.boolean :is_archived, null: false, default: false
      t.datetime :created_at
      t.datetime :updated_at
      t.jsonb :data
    end
    add_index :runn_people, :runn_id, unique: true
    add_index :runn_people, "lower(email)", name: "index_runn_people_on_lower_email"
  end
end
