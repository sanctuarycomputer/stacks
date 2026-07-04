module Mcp
  class ListOpenAdminTasksTool < MCP::Tool
    tool_name 'list_open_admin_tasks'
    description 'Stacks system-administration tasks needing attention (data hygiene, approvals, ' \
                'sync debt) from the owner-routed TaskBuilder queue (24h cache). Distinct from ' \
                'Notion Tasks, which are day-to-day work tasks. Relative urls are paths on the ' \
                'Stacks admin host; url_external true means an absolute Forecast/Notion link. ' \
                'Dollar amounts are redacted from display strings.'
    input_schema(
      properties: {
        owner: { type: 'string', description: 'Optional AdminUser email filter (case-insensitive)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(owner: nil, server_context:)
      builder = Stacks::TaskBuilder.new
      tasks =
        if owner.present?
          admin = AdminUser.find_by('LOWER(email) = ?', owner.to_s.strip.downcase)
          unless admin
            valid = AdminUser.order(:email).pluck(:email)
            return Responses.error("Unknown owner '#{owner}'. Valid owners: #{valid.join(', ')}")
          end
          builder.tasks_for(admin)
        else
          builder.tasks
        end

      rows = tasks.filter_map do |t|
        {
          type: t.type,
          task: t.humanized_type,
          subject_class: t.subject_class_key,
          subject: t.subject_display_name(redact_amounts: true),
          url: t.subject_url,
          url_external: t.subject_url_external?,
          owners: t.owners.map(&:email),
        }
      rescue StandardError => e
        Rails.logger.warn("[Mcp::ListOpenAdminTasksTool] skipping task #{t.type}: #{e.class}: #{e.message}")
        nil
      end
      rows = rows.sort_by { |r| [r[:subject_class], r[:type].to_s, r[:subject].to_s] }

      Responses.ok({ count: rows.length, tasks: rows })
    end
  end
end
