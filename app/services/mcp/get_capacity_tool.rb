module Mcp
  class GetCapacityTool < MCP::Tool
    tool_name 'get_capacity'
    description 'Resourcing capacity from the nightly utilization reports: each active ' \
                "person's sellable / benched (expected-unsold) / billable-by-rate / internal " \
                '/ time-off hours for the most recent completed period, plus unfilled ' \
                'placeholder assignments (scheduled seats with no person yet). Reads the ' \
                'persisted mirrors only — never calls Forecast live. Resourcing data (who is ' \
                'free to staff), NOT compensation or HR content.'
    GRADATIONS = ForecastPersonUtilizationReport.period_gradations.keys.freeze

    input_schema(
      properties: {
        gradation: { type: 'string', description: "#{GRADATIONS.join(', ')} (default month)" },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(gradation: 'month', server_context:)
      gradation = gradation.to_s
      unless GRADATIONS.include?(gradation)
        return Responses.error("Invalid gradation '#{gradation}'. Valid gradations: #{GRADATIONS.join(', ')}")
      end

      # Utilization reports exist only for COMPLETED periods (the nightly sync
      # walks historical Stacks::Periods), so "current" capacity is the most
      # recent persisted period; the forward-looking signal is the unfilled
      # placeholder list below.
      reports = ForecastPersonUtilizationReport
        .where(forecast_person_id: ForecastPerson.active.ids, period_gradation: gradation)
      latest = reports.maximum(:ends_at)
      records = latest ? reports.where(ends_at: latest).includes(:forecast_person).to_a : []

      rows = records.filter_map do |r|
        fp = r.forecast_person
        name = [fp.first_name, fp.last_name].compact.join(' ').strip
        {
          name: name.presence || fp.email,
          email: fp.email,
          sellable: r.expected_hours_sold.to_f,
          benched: r.expected_hours_unsold.to_f,
          billable_by_rate: (r.actual_hours_sold_by_rate || {}).transform_values(&:to_f),
          internal: r.actual_hours_internal.to_f,
          time_off: r.actual_hours_time_off.to_f,
        }
      rescue StandardError => e2
        Rails.logger.warn("[Mcp::GetCapacityTool] skipping utilization report ##{r.id}: #{e2.class}: #{e2.message}")
        Sentry.capture_exception(e2) if defined?(Sentry)
        nil
      end.sort_by { |row| row[:email].to_s }

      Responses.ok({
        gradation: gradation,
        period: {
          starts_at: records.map(&:starts_at).min&.iso8601,
          ends_at: latest && records.any? ? latest.iso8601 : nil,
        },
        people: rows,
        benched_total: rows.sum { |row| row[:benched] }.round(2),
        unfilled_placeholders: unfilled_placeholders,
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetCapacityTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_capacity failed; the error was logged')
    end

    # Placeholder assignments come from the Forecast sync with person_id nil
    # and placeholder_id set — a scheduled seat nobody has been staffed into.
    # "Unfilled" means still open (ends today or later) on a live project.
    def self.unfilled_placeholders
      ForecastAssignment
        .where(person_id: nil)
        .where.not(placeholder_id: nil)
        .where('end_date >= ?', Date.today)
        .includes(:forecast_project)
        .sort_by { |fa| [fa.start_date, fa.forecast_id].map(&:to_s) }
        .filter_map do |fa|
          project = fa.forecast_project
          next nil if project.nil? || project.archived
          {
            project: project.name,
            hours: fa.allocation_in_hours.to_f.round(2),
            start_date: fa.start_date.iso8601,
            end_date: fa.end_date.iso8601,
          }
        rescue StandardError => e2
          Rails.logger.warn("[Mcp::GetCapacityTool] skipping placeholder assignment ##{fa.forecast_id}: #{e2.class}: #{e2.message}")
          Sentry.capture_exception(e2) if defined?(Sentry)
          nil
        end
    end
  end
end
