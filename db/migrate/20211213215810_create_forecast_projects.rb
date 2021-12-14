class CreateForecastProjects < ActiveRecord::Migration[6.0]
  def change
    create_table :forecast_projects do |t|
      t.string :forecast_id
      t.jsonb :data
    end

    add_index :forecast_projects, :forecast_id, unique: true
  end
end
