module Mcp
  class GetProjectContributorsTool < MCP::Tool
    extend TrackerResolution

    tool_name 'get_project_contributors'
    description 'Who worked a project tracker and in what capacity: every contributor with ' \
                'their role periods (contributor, account/project lead, Old Deal roles), plus ' \
                'the per-workstream table the admin tracker page shows — hourly rate, hours ' \
                'over the trailing 7/30 days, total hours, and total spend. Computed live ' \
                'from Forecast assignments.'
    input_schema(
      properties: {
        tracker: { type: 'string', description: 'ProjectTracker id or exact name (case-insensitive). Required.' },
      },
      required: ['tracker']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(tracker:, server_context:)
      t = resolve_tracker(tracker)
      return unknown_tracker_error(tracker) unless t

      contributors = t.all_contributors_with_roles.filter_map do |admin_user, details|
        {
          name: admin_user.name,
          email: admin_user.email,
          roles: Array(details[:roles]).map do |role|
            {
              role: role[:name],
              started_at: role[:started_at]&.iso8601,
              ended_at: role[:ended_at]&.iso8601,
            }
          end,
        }
      rescue StandardError => e2
        Rails.logger.warn("[Mcp::GetProjectContributorsTool] skipping contributor: #{e2.class}: #{e2.message}")
        Sentry.capture_exception(e2) if defined?(Sentry)
        nil
      end.sort_by { |c| c[:email].to_s }

      today = Date.today
      workstreams = t.forecast_projects.filter_map do |fp|
        rate = fp.hourly_rate.to_f
        hours_total = fp.total_hours.to_f
        {
          name: fp.display_name,
          rate: rate,
          hours_7d: fp.total_hours_during_range(today - 6.days, today).to_f.round(2),
          hours_30d: fp.total_hours_during_range(today - 29.days, today).to_f.round(2),
          hours_total: hours_total.round(2),
          # The admin table computes spend as hours x rate (not
          # total_value_during_range) — mirror it exactly.
          spend_total: (hours_total * rate).round(2),
        }
      rescue StandardError => e2
        Rails.logger.warn("[Mcp::GetProjectContributorsTool] skipping workstream: #{e2.class}: #{e2.message}")
        Sentry.capture_exception(e2) if defined?(Sentry)
        nil
      end

      Responses.ok({
        tracker: t.name,
        id: t.id,
        url: t.external_link,
        contributors: contributors,
        workstreams: workstreams,
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetProjectContributorsTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_project_contributors failed; the error was logged')
    end
  end
end
