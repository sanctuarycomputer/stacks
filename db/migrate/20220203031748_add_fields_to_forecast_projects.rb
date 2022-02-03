class AddFieldsToForecastProjects < ActiveRecord::Migration[6.0]
  def change
    add_column :forecast_projects, :name, :string
    add_column :forecast_projects, :code, :string
    add_column :forecast_projects, :notes, :text
    add_column :forecast_projects, :start_date, :date
    add_column :forecast_projects, :end_date, :date
    add_column :forecast_projects, :harvest_id, :string
    add_column :forecast_projects, :archived, :boolean
    add_column :forecast_projects, :client_id, :string
    add_column :forecast_projects, :tags, :text, array: true, default: []
    add_column :forecast_projects, :updated_at, :datetime
    add_column :forecast_projects, :updated_by_id, :string

    add_index :forecast_projects, :client_id
  end
end
