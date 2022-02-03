class CreateForecastClients < ActiveRecord::Migration[6.0]
  def change
    create_table :forecast_clients do |t|
      t.string :forecast_id
      t.string :name
      t.string :harvest_id
      t.boolean :archived
      t.datetime :updated_at
      t.string :updated_by_id
      t.jsonb :data
    end

    add_index :forecast_clients, :forecast_id, unique: true
  end
end
