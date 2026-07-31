module Mcp
  class SetProjectTrackerWorkCompletedAtTool < MCP::Tool
    tool_name 'set_project_tracker_work_completed_at'
    description 'WRITE: mark a project tracker\'s work complete by setting work_completed_at. ' \
                'Omit completed_at to mark complete as of today; pass an ISO date/datetime to ' \
                'backdate; pass null to UNMARK (clear it). Returns {before, after}.'
    input_schema(
      properties: {
        project_tracker_id: { type: 'integer' },
        completed_at: { type: 'string', description: 'ISO date/datetime; omit = today; null = unmark' },
      },
      required: %w[project_tracker_id]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    UNSET = :__unset__

    def self.call(project_tracker_id:, completed_at: UNSET, server_context:)
      ptid = WriteValidation.integer!("project_tracker_id", project_tracker_id)
      at =
        if completed_at == UNSET
          Date.today
        elsif completed_at.nil? || completed_at.to_s.strip.empty?
          nil
        else
          WriteValidation.date!("completed_at", completed_at)
        end
      tracker = ProjectTracker.find(ptid)
      before = { work_completed_at: tracker.work_completed_at, completed: tracker.work_completed_at.present? }
      WriteGuard.check!
      tracker.mark_work_completed!(at: at)
      after = { work_completed_at: tracker.work_completed_at, completed: tracker.work_completed_at.present? }
      Responses.ok({ before: before, after: after })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("project_tracker #{project_tracker_id} not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::SetProjectTrackerWorkCompletedAtTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("set_project_tracker_work_completed_at failed; the error was logged")
    end
  end
end
