class ConvertForecastIdsToIntegers < ActiveRecord::Migration[6.0]
  def change
    change_column :forecast_projects, :forecast_id, 'integer USING CAST(forecast_id AS integer)'
    change_column :forecast_projects, :harvest_id, 'integer USING CAST(harvest_id AS integer)'
    change_column :forecast_projects, :client_id, 'integer USING CAST(client_id AS integer)'
    change_column :forecast_projects, :updated_by_id, 'integer USING CAST(updated_by_id AS integer)'

    change_column :forecast_clients, :forecast_id, 'integer USING CAST(forecast_id AS integer)'
    change_column :forecast_clients, :harvest_id, 'integer USING CAST(harvest_id AS integer)'
    change_column :forecast_clients, :updated_by_id, 'integer USING CAST(updated_by_id AS integer)'

    change_column :forecast_people, :forecast_id, 'integer USING CAST(forecast_id AS integer)'
    change_column :forecast_people, :updated_by_id, 'integer USING CAST(updated_by_id AS integer)'

    change_column :forecast_assignments, :forecast_id, 'integer USING CAST(forecast_id AS integer)'
    change_column :forecast_assignments, :updated_by_id, 'integer USING CAST(updated_by_id AS integer)'
    change_column :forecast_assignments, :project_id, 'integer USING CAST(project_id AS integer)'
    change_column :forecast_assignments, :person_id, 'integer USING CAST(person_id AS integer)'
    change_column :forecast_assignments, :placeholder_id, 'integer USING CAST(placeholder_id AS integer)'
    change_column :forecast_assignments, :repeated_assignment_set_id, 'integer USING CAST(repeated_assignment_set_id AS integer)'
  end
end
