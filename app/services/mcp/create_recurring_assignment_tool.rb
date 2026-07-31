module Mcp
  class CreateRecurringAssignmentTool < MCP::Tool
    tool_name 'create_recurring_assignment'
    description 'WRITE: create a recurring assignment for a contributor on a workstream ' \
                '(idempotent per contributor+workstream — if an ACTIVE rule already ' \
                'exists for that pair it is returned unchanged). Defaults: 8h/day, ' \
                'Mon-Fri, starts today, never ends. weekdays are 0=Sun..6=Sat (weekly = ' \
                'a single weekday, e.g. [1]). Returns {before, after, created}.'
    input_schema(
      properties: {
        contributor_id: { type: 'integer' },
        workstream_id: { type: 'integer' },
        allocation_hours: { type: 'number', description: 'default 8' },
        weekdays: { type: 'array', items: { type: 'integer' }, description: '0=Sun..6=Sat; default Mon-Fri' },
        starts_on: { type: 'string', description: 'YYYY-MM-DD; default today' },
        ends_on: { type: 'string', description: 'YYYY-MM-DD; omit = never ends' },
        notes: { type: 'string' },
        active_on_days_off: { type: 'boolean' },
      },
      required: %w[contributor_id workstream_id]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    def self.call(contributor_id:, workstream_id:, allocation_hours: 8, weekdays: [1, 2, 3, 4, 5],
                  starts_on: nil, ends_on: nil, notes: nil, active_on_days_off: false, server_context:)
      cid = WriteValidation.integer!("contributor_id", contributor_id)
      wid = WriteValidation.integer!("workstream_id", workstream_id)
      days = Array(weekdays).map { |d| WriteValidation.integer!("weekdays", d) }
      raise ArgumentError, "weekdays must be a non-empty subset of 0..6" if days.empty? || days.any? { |d| !(0..6).cover?(d) }
      hours = begin
        Float(allocation_hours)
      rescue ArgumentError, TypeError
        nil
      end
      raise ArgumentError, "allocation_hours must be greater than 0" if hours.nil? || hours <= 0
      start_date = starts_on.present? ? WriteValidation.date!("starts_on", starts_on) : Date.today
      end_date = ends_on.present? ? WriteValidation.date!("ends_on", ends_on) : nil
      raise ArgumentError, "ends_on must be on or after starts_on" if end_date && end_date < start_date
      note = notes.nil? ? "" : WriteValidation.short_string!("notes", notes, 2000)

      contributor = Contributor.find(cid)
      workstream = ProjectTrackerForecastProject.find(wid)

      existing = RecurringAssignment.active.find_by(
        forecast_person_id: contributor.forecast_person_id,
        forecast_project_id: workstream.forecast_project_id,
      )
      if existing
        return Responses.ok({ before: ra_json(existing, contributor, workstream), after: ra_json(existing, contributor, workstream), created: false })
      end

      WriteGuard.check!
      ra = RecurringAssignment.new(
        forecast_person_id: contributor.forecast_person_id,
        forecast_project_id: workstream.forecast_project_id,
        weekdays: days,
        starts_on: start_date,
        ends_on: end_date,
        notes: note,
        active_on_days_off: active_on_days_off ? true : false,
      )
      ra.allocation_in_hours = hours
      ra.save!
      Responses.ok({ before: nil, after: ra_json(ra, contributor, workstream), created: true })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("contributor or workstream not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::CreateRecurringAssignmentTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("create_recurring_assignment failed; the error was logged")
    end

    def self.ra_json(ra, contributor, workstream)
      {
        id: ra.id, contributor_id: contributor.id, workstream_id: workstream.id,
        allocation_hours: ra.allocation_in_hours, weekdays: ra.weekdays,
        starts_on: ra.starts_on, ends_on: ra.ends_on,
      }
    end
  end
end
