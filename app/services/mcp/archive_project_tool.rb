module Mcp
  class ArchiveProjectTool < MCP::Tool
    tool_name 'archive_project'
    description 'WRITE: archive (or unarchive) a projection project. Refuses CONFIRMED projects ' \
                'unless allow_confirmed is true — archiving real engagements is a human-signed act. ' \
                'Intended for dead-deal tentative shells.'
    input_schema(
      properties: {
        project_id: { type: 'integer' },
        is_archived: { type: 'boolean', description: 'true to archive, false to restore' },
        allow_confirmed: { type: 'boolean', description: 'Required true to touch a confirmed project' },
      },
      required: %w[project_id is_archived]
    )
    annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: true)

    def self.call(project_id:, is_archived:, allow_confirmed: false, server_context:)
      pid = WriteValidation.integer!("project_id", project_id)

      # FAIL CLOSED: the nightly-synced mirror is the cheap source of truth,
      # and only a mirror row that explicitly says is_confirmed=false unlocks
      # the unguarded path. A missing row (project newer than the last sync)
      # or a nil flag is treated as confirmed.
      mirror = RunnProject.find_by(runn_id: pid)
      explicitly_tentative = mirror && mirror.is_confirmed == false
      if !explicitly_tentative && !allow_confirmed
        reason = mirror.nil? ? "is not in the nightly mirror yet" : "is confirmed"
        raise ArgumentError, "project #{pid} #{reason}; archiving it requires allow_confirmed: true"
      end

      WriteGuard.check!
      before = mirror && { runn_id: mirror.runn_id, name: mirror.name, is_archived: mirror.is_archived, is_confirmed: mirror.is_confirmed }
      project = Stacks::Runn.new(max_retries: 0).update_project(pid, is_archived: is_archived)
      Responses.ok({ before: before, after: project })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ArchiveProjectTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("archive_project failed; the error was logged")
    end
  end
end
