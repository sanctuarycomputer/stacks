class CreateDeelPeople < ActiveRecord::Migration[6.0]
  def change
    create_table :deel_people do |t|
      t.string :deel_id, null: false
      t.jsonb :data, null: false
    end

    add_index :deel_people, :deel_id, unique: true
  end
end