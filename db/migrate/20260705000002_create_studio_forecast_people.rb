class CreateStudioForecastPeople < ActiveRecord::Migration[6.1]
  def change
    create_table :studio_forecast_people do |t|
      t.references :studio, null: false, foreign_key: true, index: false
      # No `foreign_key: true` here: ForecastPerson overrides
      # `self.primary_key = "forecast_id"`, so `fp.id` (and every other
      # forecast_person_id column in this app — Contributor, Trueup,
      # ForecastPersonUtilizationReport, ContributorPayout) actually stores
      # the forecast_id business key, not the row's real serial `id`. A
      # default `foreign_key: true` here would target forecast_people.id
      # and reject every insert. We add the FK explicitly below, against
      # forecast_id (which has a unique index), matching that convention.
      t.references :forecast_person, null: false
      t.timestamps
    end

    add_foreign_key :studio_forecast_people, :forecast_people, column: :forecast_person_id, primary_key: :forecast_id
    add_index :studio_forecast_people, [:studio_id, :forecast_person_id], unique: true, name: "index_studio_forecast_people_on_studio_and_forecast_person"
  end
end
