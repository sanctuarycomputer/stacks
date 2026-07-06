class CreateForecastPeople < ActiveRecord::Migration[6.0]
  def change
    create_table :forecast_people do |t|
      t.string :forecast_id
      t.string :first_name
      t.string :last_name
      t.string :email
      t.text :roles, array: true, default: []
      t.boolean :archived
      t.datetime :updated_at
      t.string :updated_by_id
      t.jsonb :data
    end

    add_index :forecast_people, :forecast_id, unique: true
  end
end
