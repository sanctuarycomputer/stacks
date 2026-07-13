module Mcp
  class GetResourcingProjectionsTool < MCP::Tool
    tool_name 'get_resourcing_projections'
    description 'The resourcing PROJECTION plane: forward planned assignments (minutes_per_day, placeholders), ' \
                'people, and projects with the tentative flag (is_confirmed=false), window-filtered ' \
                'from today. Where a project maps to a ProjectTracker, its snapshot dates, hours, and ' \
                'recent_actuals (who actually worked it in the trailing 3 weeks, at what cadence) are ' \
                'joined — the extrapolation fuel for unprojected work. Live read; never touches actuals-the-plane.'
    input_schema(
      properties: {
        window_days: { type: 'number', description: 'Horizon in days from today (default 90). Assignments overlapping [today, today + window_days] are returned.' },
        include_archived: { type: 'boolean', description: 'Default false. Include archived projects (and their assignments).' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    RECENT_WINDOW_DAYS = 21

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

      # full history retained: recent_actuals derives last-known roles from it
      raw_assignments = runn.get_assignments.reject { |a| a["isTemplate"] }
      raw_people = runn.get_people

      assignments = raw_assignments.select do |a|
        next false unless project_ids.include?(a["projectId"])

        start_date = begin; Date.parse(a["startDate"].to_s); rescue ArgumentError, TypeError; nil; end
        end_date   = begin; Date.parse(a["endDate"].to_s);   rescue ArgumentError, TypeError; nil; end
        next false if start_date.nil? || end_date.nil?

        end_date >= today && start_date <= horizon
      end

      trackers_by_runn_id = ProjectTracker
        .where(runn_project_id: project_ids.to_a)
        .index_by(&:runn_project_id)

      recent_actuals_by_runn_id = recent_actuals(trackers_by_runn_id, raw_people, raw_assignments, today)

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
            recent_actuals: recent_actuals_by_runn_id[p["id"]] || [],
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
        people: raw_people
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

    # Who actually worked each tracker-mapped project in the trailing window,
    # at what observed cadence — from the local Forecast mirror (zero provider
    # calls). Emails are matched internally and never emitted. role_id is the
    # person's most recent historical assignment role (same project preferred)
    # so extrapolated projections can be created without guessing roles.
    def self.recent_actuals(trackers_by_runn_id, raw_people, raw_assignments, today)
      cutoff = today - RECENT_WINDOW_DAYS
      # archived people last so an active rehire with the same email wins the index
      runn_id_by_email = raw_people
        .sort_by { |p| p["isArchived"] ? 1 : 0 }
        .each_with_object({}) do |p, h|
          email = (p["email"] || "").downcase
          h[email] = p["id"] if !email.empty? && (!h.key?(email) || !p["isArchived"])
        end
      name_by_person_id = raw_people.each_with_object({}) do |p, h|
        h[p["id"]] = [p["firstName"], p["lastName"]].compact.join(" ")
      end
      history_by_person = raw_assignments.group_by { |a| a["personId"] }

      trackers_by_runn_id.each_with_object({}) do |(runn_id, tracker), out|
        # per person: date → minutes, so overlapping ForecastAssignments SUM
        # on shared days instead of diluting the average
        minutes_by_person_day = Hash.new { |h, k| h[k] = Hash.new(0.0) }
        tracker.forecast_assignments
          .includes(:forecast_person, forecast_project: :forecast_client)
          .where("forecast_assignments.end_date >= ?", cutoff)
          .each do |fa|
            next if fa.is_time_off?

            person_id = runn_id_by_email[(fa.forecast_person&.email || "").downcase]
            next if person_id.nil?

            window_start = [fa.start_date, cutoff].max
            window_end = [fa.end_date, today].min
            next if window_start > window_end

            # nil allocation means full-time in Forecast's own semantics
            # (see ForecastAssignment#allocation_in_seconds)
            daily_minutes = (fa.allocation || Stacks::System.singleton_class::EIGHT_HOURS_IN_SECONDS) / 60.0
            (window_start..window_end).each do |d|
              next unless (1..5).cover?(d.wday)
              minutes_by_person_day[person_id][d] += daily_minutes
            end
          end

        out[runn_id] = minutes_by_person_day.map do |person_id, by_day|
          history = history_by_person[person_id] || []
          same_project = history.select { |a| a["projectId"] == runn_id }
          latest = (same_project.presence || history).max_by { |a| a["endDate"].to_s }
          {
            person_id: person_id,
            name: name_by_person_id[person_id],
            avg_minutes_per_day: (by_day.values.sum / by_day.size).round,
            last_active_on: by_day.keys.max.iso8601,
            role_id: latest && latest["roleId"],
          }
        end.sort_by { |e| -e[:avg_minutes_per_day] }
      end
    rescue StandardError => e
      # recent_actuals is enrichment — its failure degrades, never breaks, the read
      Rails.logger.warn("[Mcp::GetResourcingProjectionsTool] recent_actuals failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      {}
    end
    private_class_method :recent_actuals
  end
end
