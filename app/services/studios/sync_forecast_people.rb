module Studios
  # Materializes Studio#forecast_people into studio_forecast_people so
  # utilization aggregation can happen in SQL. Deliberately implemented BY
  # CALLING Studio#forecast_people — the Ruby heuristics (admin_user studio
  # memberships, Forecast role-name matching, garden3d-gets-everyone) stay
  # the single source of truth and this table can never drift in logic,
  # only in time. Full rebuild each run; the table is tiny.
  #
  # `fp.id` here is ForecastPerson's forecast_id business key, not the
  # row's real serial id column — ForecastPerson overrides
  # `self.primary_key = "forecast_id"`, so `.id` resolves through that
  # override (a Rails ActiveRecord::AttributeMethods::PrimaryKey quirk).
  # That's exactly what we want to store: studio_forecast_people's FK
  # (see the migration) targets forecast_people.forecast_id, matching
  # every other forecast_person_id column in this app (Contributor,
  # Trueup, ContributorPayout, ForecastPersonUtilizationReport).
  class SyncForecastPeople
    def self.call(all_studios: Studio.all.to_a)
      now = Time.current
      rows = all_studios.flat_map do |studio|
        studio.forecast_people(all_studios).map do |fp|
          {
            studio_id: studio.id,
            forecast_person_id: fp.id,
            created_at: now,
            updated_at: now,
          }
        end
      end

      ActiveRecord::Base.transaction do
        StudioForecastPerson.delete_all
        StudioForecastPerson.insert_all!(rows) if rows.any?
      end
    end
  end
end
