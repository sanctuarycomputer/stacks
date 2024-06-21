class CreateRunnPeople < ActiveRecord::Migration[6.0]
  def change
    create_table :runn_people do |t|
      t.bigint :runn_id
      t.string :first_name
      t.string :last_name
      t.string :email
      t.boolean :is_archived
      t.datetime :created_at
      t.datetime :updated_at
      t.jsonb :data
    end

    add_index :runn_people, :runn_id, unique: true
  end
end
