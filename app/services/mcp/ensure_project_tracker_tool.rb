module Mcp
  class EnsureProjectTrackerTool < MCP::Tool
    tool_name 'ensure_project_tracker'
    description 'WRITE: ensure a project tracker named <name> exists (idempotent). ' \
                'If none exists, creates a bare tracker with MSA/SOW links (missing ' \
                'links become placeholders and are reported in warnings). If exactly ' \
                'one exists, returns it unchanged. If more than one matches the name, ' \
                'errors — disambiguate with list_project_trackers. Returns ' \
                '{before, after, created, warnings}.'
    input_schema(
      properties: {
        name: { type: 'string' },
        msa_url: { type: 'string' },
        sow_url: { type: 'string' },
        budget_low_end: { type: 'integer' },
        budget_high_end: { type: 'integer' },
      },
      required: %w[name]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    def self.call(name:, msa_url: nil, sow_url: nil, budget_low_end: nil, budget_high_end: nil, server_context:)
      clean = WriteValidation.short_string!("name", name.to_s.strip, 255)
      raise ArgumentError, "name must be non-empty" if clean.empty?

      matches = ProjectTracker.where("lower(name) = ?", clean.downcase).to_a
      if matches.length > 1
        raise ArgumentError, "multiple project trackers named '#{clean}'; disambiguate with list_project_trackers and use the specific id"
      elsif matches.length == 1
        json = ProvisioningSerializers.tracker_json(matches.first)
        return Responses.ok({ before: json, after: json, created: false })
      end

      WriteGuard.check!
      tracker, warnings = ProjectTracker.provision!(
        name: clean, msa_url: msa_url, sow_url: sow_url,
        budget_low_end: budget_low_end, budget_high_end: budget_high_end,
      )
      Responses.ok({ before: nil, after: ProvisioningSerializers.tracker_json(tracker), created: true, warnings: warnings })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::EnsureProjectTrackerTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("ensure_project_tracker failed; the error was logged")
    end
  end
end
