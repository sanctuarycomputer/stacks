class IndexesForPerformance < ActiveRecord::Migration[6.0]
  def up
    execute 'CREATE EXTENSION IF NOT EXISTS btree_gist;'

    # The Basics
    add_index :forecast_assignments, :start_date
    add_index :forecast_assignments, :end_date
    add_index :forecast_assignments, :allocation
    add_index :forecast_assignments, [:project_id, :start_date]

    add_index :forecast_assignments,
              [:start_date, :end_date],
              using: :gist,
              name: 'idx_assignments_on_daterange'

    # For person + date range queries
    add_index :forecast_assignments,
              [:person_id, :start_date, :end_date],
              using: :gist,
              name: 'idx_assignments_on_person_and_daterange'

    # For project + date range queries
    add_index :forecast_assignments,
              [:project_id, :start_date, :end_date],
              using: :gist,
              name: 'idx_assignments_on_project_and_daterange'

    # For queries filtering by both person and project with dates
    add_index :forecast_assignments,
              [:person_id, :project_id, :start_date, :end_date],
              using: :gist,
              name: 'idx_assignments_on_person_project_and_daterange'
  end

  def down
    remove_index :forecast_assignments, name: 'idx_assignments_on_daterange'
    remove_index :forecast_assignments, name: 'idx_assignments_on_person_and_daterange'
    remove_index :forecast_assignments, name: 'idx_assignments_on_project_and_daterange'
    remove_index :forecast_assignments, name: 'idx_assignments_on_person_project_and_daterange'

    remove_index :forecast_assignments, :start_date
    remove_index :forecast_assignments, :end_date
    remove_index :forecast_assignments, :allocation
    remove_index :forecast_assignments, [:project_id, :start_date]

    execute 'DROP EXTENSION IF EXISTS btree_gist;'
  end
end
