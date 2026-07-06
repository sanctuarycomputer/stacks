module Mcp
  class GetCapacityTool < MCP::Tool
    tool_name 'get_capacity'
    description 'Per-person capacity / resourcing from the nightly utilization reports: each ' \
                'active person\'s sellable / billable / internal / time-off / unsold hours, ' \
                'utilization rate, and whether they are benched (have unsold hours to staff). ' \
                'Reads persisted reports only — never calls Forecast live. This is resourcing ' \
                'data (who is free to staff), NOT compensation, HR, or 1:1 content.'
    input_schema(
      properties: {
        studio: { type: 'string', description: 'Optional studio name or mini_name; default all studios' },
        gradation: { type: 'string', description: 'month (default), quarter, year, trailing_3_months, trailing_4_months, trailing_6_months, trailing_12_months' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    GRADATIONS = ForecastPersonUtilizationReport.period_gradations.keys.freeze

    def self.call(studio: nil, gradation: 'month', server_context:)
      grad = gradation.to_s
      unless GRADATIONS.include?(grad)
        return Responses.error("Invalid gradation '#{grad}'. Valid: #{GRADATIONS.join(', ')}")
      end

      # Both the all-studios and studio-filtered paths derive the person set
      # from the SAME ForecastPerson.active scope, so "active" means exactly one
      # thing (its SQL where.not(archived: true) — a NULL-archived row is
      # excluded, unlike a Ruby reject(&:archived) which would keep it). The
      # studio path then intersects with the studio's member ids. #ids (not a
      # literal pluck(:id)) respects ForecastPerson's forecast_id primary-key
      # override — the value ForecastPersonUtilizationReport#forecast_person_id
      # stores. The extra active.ids query on the studio path is deliberate:
      # correctness/consistency over saving one cheap single-column pluck.
      active_ids = ForecastPerson.active.ids
      studio_label = 'all'
      if studio.present?
        all_studios = Studio.all.to_a
        key = studio.to_s.strip
        match = all_studios.find { |s| s.name.to_s.casecmp?(key) } ||
                all_studios.find { |s| s.mini_name.to_s.split(',').map(&:strip).any? { |m| m.casecmp?(key) } }
        unless match
          valid = all_studios.map { |s| "#{s.name} (#{s.mini_name})" }.sort.join(', ')
          return Responses.error("Unknown studio '#{studio}'. Valid studios: #{valid}")
        end
        studio_label = match.name
        studio_person_ids = match.forecast_people(all_studios).map(&:id).to_set
        active_ids = active_ids.select { |id| studio_person_ids.include?(id) }
      end

      reports = ForecastPersonUtilizationReport
        .where(forecast_person_id: active_ids, period_gradation: grad)
      # Now-state: the most recent persisted period for this gradation.
      latest = reports.maximum(:ends_at)
      if latest.nil?
        return Responses.ok(gradation: grad, period: { starts_at: nil, ends_at: nil },
                            studio: studio_label, benched_count: 0, people: [])
      end
      records = reports.where(ends_at: latest).includes(:forecast_person).to_a
      # TOCTOU: the rows behind `latest` could be deleted between the maximum()
      # query and this one (e.g. the nightly regen job runs mid-request). Treat
      # a now-empty set like "no reports" rather than letting nil.starts_at raise.
      if records.empty?
        return Responses.ok(gradation: grad, period: { starts_at: nil, ends_at: nil },
                            studio: studio_label, benched_count: 0, people: [])
      end
      # All reports for this gradation+ends_at should share starts_at, but the
      # set is unordered — read it deterministically rather than relying on
      # incidental record order.
      starts_at = records.map(&:starts_at).min

      rows = records.filter_map do |r|
        {
          person: r.forecast_person.email,
          sellable_hours: r.expected_hours_sold.to_f,
          billable_hours: r.actual_hours_sold.to_f,
          internal_hours: r.actual_hours_internal.to_f,
          time_off_hours: r.actual_hours_time_off.to_f,
          unsold_hours: r.expected_hours_unsold.to_f,
          utilization_rate: r.utilization_rate.to_f,
          benched: r.expected_hours_unsold.to_f.positive?,
        }
      rescue StandardError => e
        Rails.logger.warn("[Mcp::GetCapacityTool] skipping utilization report id=#{r.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end.sort_by { |x| x[:person].to_s }

      # records is guaranteed non-empty here (the empty case returned early
      # above), so rows.empty? means every row failed to map — a systemic
      # read/serialization regression, not a normal "no data" state.
      if rows.empty?
        Rails.logger.warn("[Mcp::GetCapacityTool] all #{records.size} utilization reports for #{latest} failed to map — returning an empty roster; investigate a read/serialization regression.")
      end

      Responses.ok(
        gradation: grad,
        period: { starts_at: starts_at.iso8601, ends_at: latest.iso8601 },
        studio: studio_label,
        benched_count: rows.count { |x| x[:benched] },
        people: rows
      )
    end
  end
end
