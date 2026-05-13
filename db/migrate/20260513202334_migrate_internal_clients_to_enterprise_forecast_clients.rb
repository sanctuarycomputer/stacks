class MigrateInternalClientsToEnterpriseForecastClients < ActiveRecord::Migration[6.1]
  # Until now, ForecastClient#is_internal? checked a hardcoded constant
  # (ForecastClient::INTERNAL_CLIENTS) and the enterprise_forecast_clients
  # join existed *separately* as an explicit per-enterprise mapping. Two
  # sources of truth that could disagree. This migration consolidates onto
  # the join — for every legacy hardcoded name that has both a matching
  # forecast_client AND a matching enterprise, ensure a join row exists.
  # The constant is dropped in the application-code commit that follows.
  #
  # Pairs that don't have both sides present (e.g., local dev without a
  # "Garden3D LLC" enterprise) are skipped silently — admins can map them
  # via /admin/enterprises/:id/edit after deploy.
  def up
    name_to_enterprise = {
      "garden3d"           => "Garden3D LLC",
      "Sanctuary Computer" => Enterprise::SANCTUARY_NAME,
      "Seaborne"           => Enterprise::SANCTUARY_NAME,
      "XXIX"               => Enterprise::SANCTUARY_NAME,
      "XXXI"               => Enterprise::SANCTUARY_NAME,
      "Crystalizer"        => Enterprise::SANCTUARY_NAME,
      "Index Space LLC"    => "Index Space LLC",
    }

    seeded = 0
    skipped = []
    name_to_enterprise.each do |client_name, enterprise_name|
      fc = ForecastClient.find_by(name: client_name)
      ent = Enterprise.find_by(name: enterprise_name)
      if fc.nil?
        skipped << "no forecast_client named #{client_name.inspect}"
        next
      end
      if ent.nil?
        skipped << "no enterprise named #{enterprise_name.inspect} (for forecast_client #{client_name.inspect})"
        next
      end

      existing = EnterpriseForecastClient.find_by(forecast_client_id: fc.forecast_id)
      if existing
        if existing.enterprise_id != ent.id
          say "Forecast client #{client_name.inspect} already mapped to enterprise ##{existing.enterprise_id}; leaving as-is"
        end
        next
      end

      EnterpriseForecastClient.create!(forecast_client_id: fc.forecast_id, enterprise: ent)
      seeded += 1
      say "Mapped forecast_client #{client_name.inspect} → enterprise #{enterprise_name.inspect}"
    end

    say "Seeded #{seeded} enterprise_forecast_clients row(s). Skipped:"
    skipped.each { |s| say "  - #{s}" }
  end

  def down
    # No-op — admins may have edited mappings after the migration ran;
    # we don't want to clobber their intent on rollback.
  end
end
