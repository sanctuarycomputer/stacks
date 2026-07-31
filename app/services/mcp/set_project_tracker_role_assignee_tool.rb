module Mcp
  class SetProjectTrackerRoleAssigneeTool < MCP::Tool
    tool_name 'set_project_tracker_role_assignee'
    description 'WRITE: set the account_lead or project_lead of a project tracker (the assignee ' \
                'is identified by their email — the same email as their contributor record). ' \
                'Lead changes take effect at month ' \
                'boundaries: the prior lead ends at the end of the prior month and the new lead ' \
                'starts on the first of starts_on\'s month (default this month). No-op if already ' \
                'the lead. A same-month swap is refused (resolve in the admin UI). Returns {before, after}.'
    input_schema(
      properties: {
        project_tracker_id: { type: 'integer' },
        role: { type: 'string', description: '"account_lead" or "project_lead"' },
        admin_user_email: { type: 'string' },
        starts_on: { type: 'string', description: 'YYYY-MM-DD, must be the first of a month; default this month' },
      },
      required: %w[project_tracker_id role admin_user_email]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    def self.call(project_tracker_id:, role:, admin_user_email:, starts_on: nil, server_context:)
      ptid = WriteValidation.integer!("project_tracker_id", project_tracker_id)
      raise ArgumentError, "role must be one of #{ProjectTracker::ROLE_PERIOD_ASSOCIATIONS.keys.join(', ')}" unless ProjectTracker::ROLE_PERIOD_ASSOCIATIONS.key?(role.to_s)
      start_date = starts_on.present? ? WriteValidation.date!("starts_on", starts_on) : Date.today.beginning_of_month

      tracker = ProjectTracker.find(ptid)
      admin = AdminUser.where("lower(email) = ?", admin_user_email.to_s.strip.downcase).first
      raise ArgumentError, "admin user #{admin_user_email} not found" if admin.nil?

      before = lead_snapshot(tracker, role)
      current = tracker.public_send(ProjectTracker::ROLE_PERIOD_ASSOCIATIONS[role.to_s]).detect { |p| p.ended_at.nil? }
      WriteGuard.check! unless current&.admin_user_id == admin.id
      tracker.set_role_assignee!(role: role, admin_user: admin, starts_on: start_date)
      Responses.ok({ before: before, after: lead_snapshot(tracker.reload, role) })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("project_tracker #{project_tracker_id} not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::SetProjectTrackerRoleAssigneeTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("set_project_tracker_role_assignee failed; the error was logged")
    end

    def self.lead_snapshot(tracker, role)
      period = tracker.public_send(ProjectTracker::ROLE_PERIOD_ASSOCIATIONS[role.to_s]).detect { |p| p.ended_at.nil? }
      au = period&.admin_user
      { role: role.to_s, assignee: au && { name: au.display_name, email: au.email } }
    end
  end
end
