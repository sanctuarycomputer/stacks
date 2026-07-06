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

      # ForecastPerson overrides its primary_key to forecast_id (the column
      # ForecastPersonUtilizationReport#forecast_person_id actually stores),
      # while the table also has an unrelated surrogate "id" column. #ids
      # (unlike a literal pluck(:id)) respects that primary_key override, so
      # it plucks the same values `.map(&:id)` would.
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
        # match.forecast_people is a plain Ruby Array (built in Ruby, not an
        # AR::Relation), so pluck isn't available/safe here — map(&:id) is
        # the correct id extraction (see note above on the primary_key override).
        studio_person_ids = match.forecast_people.map(&:id).to_set
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
      period_reports = reports.where(ends_at: latest).includes(:forecast_person)
      starts_at = period_reports.first.starts_at

      rows = period_reports.filter_map do |r|
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
