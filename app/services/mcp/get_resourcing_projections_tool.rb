module Mcp
  class GetResourcingProjectionsTool < MCP::Tool
    tool_name 'get_resourcing_projections'
    description 'The resourcing PROJECTION plane: forward planned assignments (minutes_per_day, placeholders), ' \
                'people, and projects with the tentative flag (is_confirmed=false), window-filtered ' \
                'from today. Where a project maps to a ProjectTracker, its snapshot dates and ' \
                'hours are joined for divergence checks. Live read of the resourcing tool; never touches actuals.'
    input_schema(
      properties: {
        window_days: { type: 'number', description: 'Horizon in days from today (default 90). Assignments overlapping [today, today + window_days] are returned.' },
        include_archived: { type: 'boolean', description: 'Default false. Include archived projects (and their assignments).' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(window_days: 90, include_archived: false, server_context:)
      # Request path: no 429 sleep-retry (a rate limit must never park a web
      # worker), and the window is clamped to sane bounds.
      runn = Stacks::Runn.new(max_retries: 0)
      window_days = window_days.to_f.finite? ? window_days.to_i.clamp(1, 365) : 90
      today = Time.zone.today
      horizon = today + window_days.days

      projects = runn.get_projects.reject { |p| p["isTemplate"] }
      projects = projects.reject { |p| p["isArchived"] } unless include_archived
      project_ids = projects.map { |p| p["id"] }.to_set

      assignments = runn.get_assignments.select do |a|
        next false if a["isTemplate"]
        next false unless project_ids.include?(a["projectId"])

        start_date = begin; Date.parse(a["startDate"].to_s); rescue ArgumentError, TypeError; nil; end
        end_date   = begin; Date.parse(a["endDate"].to_s);   rescue ArgumentError, TypeError; nil; end
        next false if start_date.nil? || end_date.nil?

        end_date >= today && start_date <= horizon
      end

      trackers_by_runn_id = ProjectTracker
        .where(runn_project_id: project_ids.to_a)
        .index_by(&:runn_project_id)

      Responses.ok({
        as_of: today.iso8601,
        window: { start: today.iso8601, end: horizon.iso8601 },
        projects: projects.map { |p|
          tracker = trackers_by_runn_id[p["id"]]
          {
            id: p["id"],
            name: p["name"],
            is_confirmed: p["isConfirmed"],
            is_archived: p["isArchived"],
            client_id: p["clientId"],
            budget: p["budget"],
            pricing_model: p["pricingModel"],
            url: "https://app.runn.io/projects/#{p['id']}",
            project_tracker: tracker && {
              id: tracker.id,
              name: tracker.name,
              snapshot_start_date: tracker.snapshot&.dig("first_forecast_assignment_start_date"),
              snapshot_end_date: tracker.snapshot&.dig("last_forecast_assignment_end_date"),
              hours_total: tracker.snapshot&.dig("hours_total"),
              hours_free: tracker.snapshot&.dig("hours_free"),
            },
          }
        },
        people: runn.get_people
          .reject { |p| p["isArchived"] && !include_archived }
          .map { |p|
            # deliberately no email — assignments join on id; former-staff
            # emails don't belong on this surface (matches get_studio_health's
            # precedent of excluding per-person contact detail)
            {
              id: p["id"],
              name: [p["firstName"], p["lastName"]].compact.join(" "),
              is_archived: p["isArchived"],
            }
          },
        assignments: assignments.map { |a|
          {
            id: a["id"],
            person_id: a["personId"],
            project_id: a["projectId"],
            role_id: a["roleId"],
            start_date: a["startDate"],
            end_date: a["endDate"],
            minutes_per_day: a["minutesPerDay"],
            is_placeholder: a["isPlaceholder"],
            is_active: a["isActive"],
            note: a["note"],
          }
        },
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetResourcingProjectionsTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      # never echo upstream/internal error bodies to the caller
      Responses.error("get_resourcing_projections failed; the error was logged")
    end
  end
end
