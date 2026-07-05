module Mcp
  class ListOpenAdminTasksTool < MCP::Tool
    tool_name 'list_open_admin_tasks'
    description 'Stacks system-administration tasks needing attention (data hygiene, approvals, ' \
                "sync debt) from the owner-routed TaskBuilder queue (#{Stacks::TaskBuilder::CACHE_TTL.inspect} cache). Distinct from " \
                'Notion Tasks, which are day-to-day work tasks. Relative urls are paths on the ' \
                'Stacks admin host; url_external true means an absolute Forecast/Notion link. ' \
                'Compensation-adjacent amounts (reimbursements, contributor ledger adjustments) ' \
                'are redacted from display strings; operational names (projects, leads, surveys) ' \
                'pass through as-is.'
    input_schema(
      properties: {
        owner: { type: 'string', description: 'Optional AdminUser email filter (case-insensitive; blank/whitespace means no filter)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(owner: nil, server_context:)
      builder = Stacks::TaskBuilder.new
      tasks =
        if owner.present?
          # Any real admin's email resolves — a taskless admin gets an honest
          # empty list, not an error. Ruby-side casecmp? keeps matching
          # Unicode-safe regardless of DB collation; the admin table is small.
          admin = AdminUser.all.to_a.find { |a| a.email.casecmp?(owner.to_s.strip) }
          unless admin
            # Suggest emails of CURRENT queue owners, derived from the same
            # hydrated tasks the unfiltered call renders (raw cached owner_ids
            # could also name owners of tasks hydration skips, e.g. a deleted
            # subject). One narrow caveat: if an owner's only task is being
            # dropped by the mapping rescue below, their email can appear here
            # without appearing in payloads — acceptable, these are internal
            # admin emails behind the same API key. Error path only, so the
            # hydration cost doesn't touch the happy path.
            valid = builder.tasks.flat_map(&:owners).map(&:email).uniq.sort
            roster = valid.any? ? " Current task owners: #{valid.join(', ')}" : ' The task queue is currently empty.'
            return Responses.error("Unknown owner '#{owner}'.#{roster}")
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
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end
      rows = rows.sort_by { |r| [r[:subject_class], r[:type].to_s, r[:subject].to_s] }

      Responses.ok({ count: rows.length, tasks: rows })
    end
  end
end
