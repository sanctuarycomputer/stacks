module Mcp
  class FindAdminUserTool < MCP::Tool
    tool_name 'find_admin_user'
    description 'READ: find garden3d staff (AdminUser) by email (exact, case-insensitive). ' \
                'Returns [{id, name, email}]. Use the id as admin_user for project-tracker ' \
                'lead roles (account_lead / project_lead) — distinct from find_contributor, ' \
                'which resolves assignees.'
    input_schema(properties: { email: { type: 'string' } }, required: %w[email])
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(email:, server_context:)
      rows = AdminUser.where("lower(email) = ?", email.to_s.strip.downcase).map do |a|
        { id: a.id, name: a.display_name, email: a.email }
      end
      Responses.ok(rows)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::FindAdminUserTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("find_admin_user failed; the error was logged")
    end
  end
end
