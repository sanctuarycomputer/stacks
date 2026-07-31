module Mcp
  class EnsureWorkstreamTool < MCP::Tool
    tool_name 'ensure_workstream'
    description 'WRITE: ensure a workstream with the given code exists on a project ' \
                'tracker at the given rate (idempotent). If the code is absent, creates ' \
                'the workstream — a tracker\'s FIRST workstream also needs client_name. ' \
                'If the code is present, adds the rate only if missing. rate is a string ' \
                'like "450p/h" or "450". Returns ' \
                '{before, after, created, rate_added}.'
    input_schema(
      properties: {
        project_tracker_id: { type: 'integer' },
        name: { type: 'string' },
        code: { type: 'string' },
        rate: { type: 'string', description: 'rate as a string, e.g. "450p/h" or "450"' },
        client_name: { type: 'string', description: 'required for a tracker\'s first workstream' },
      },
      required: %w[project_tracker_id name code rate]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    def self.call(project_tracker_id:, name:, code:, rate:, client_name: nil, server_context:)
      ptid = WriteValidation.integer!("project_tracker_id", project_tracker_id)
      nm = WriteValidation.short_string!("name", name.to_s.strip, 255)
      cd = WriteValidation.short_string!("code", code.to_s.strip, 255)
      raise ArgumentError, "name must be non-empty" if nm.empty?
      raise ArgumentError, "code must be non-empty" if cd.empty?
      validate_rate!(rate)

      tracker = ProjectTracker.find(ptid)
      existing = tracker.project_tracker_forecast_projects.detect { |ws| ws.forecast_project&.code&.casecmp?(cd) }

      if existing
        tag = Stacks::Forecast.rate_tag(rate)
        already = Array(existing.forecast_project&.tags).include?(tag)
        if already
          json = ProvisioningSerializers.workstream_json(existing)
          return Responses.ok({ before: json, after: json, created: false, rate_added: false })
        end
        before = ProvisioningSerializers.workstream_json(existing)
        WriteGuard.check!
        Stacks::Forecast.new.add_project_rate!(existing.forecast_project_id, rate)
        return Responses.ok({ before: before, after: ProvisioningSerializers.workstream_json(existing.reload), created: false, rate_added: true })
      end

      WriteGuard.check!
      ws = tracker.add_workstream!(name: nm, code: cd, rate: rate, client_name: client_name)
      Responses.ok({ before: nil, after: ProvisioningSerializers.workstream_json(ws), created: true, rate_added: true })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("project_tracker #{project_tracker_id} not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::EnsureWorkstreamTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("ensure_workstream failed; the error was logged")
    end

    def self.validate_rate!(rate)
      s = rate.to_s.delete("$").strip.sub(/p\/h\z/, "")
      f = begin
        Float(s)
      rescue ArgumentError, TypeError
        nil
      end
      raise ArgumentError, 'rate must be a positive number or "Np/h" string' if f.nil? || f <= 0
    end
  end
end
