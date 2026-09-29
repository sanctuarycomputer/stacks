module Mcp
  class UpdateProjectTrackerTool < MCP::Tool
    tool_name 'update_project_tracker'
    description 'WRITE: update an existing project tracker — set name, the overall budget band, ' \
                'the monthly budget (retainers), and/or replace the MSA/SOW/Twist-channel/' \
                'Notion-homepage links (only provided fields change). Monthly budget: pass ONE ' \
                'end for a fixed monthly budget at that number (it sets both ends), BOTH for a ' \
                'range, or clear_monthly_budget: true to remove it. Use this to fix the ' \
                'placeholder MSA/SOW links left by ensure_project_tracker. Returns {before, after}.'
    input_schema(
      properties: {
        project_tracker_id: { type: 'integer' },
        name: { type: 'string' },
        budget_low_end: { type: 'number' },
        budget_high_end: { type: 'number' },
        monthly_budget_low_end: { type: 'number', description: 'Monthly budget low end (USD, > 0). Alone = a fixed monthly budget.' },
        monthly_budget_high_end: { type: 'number', description: 'Monthly budget high end (USD, > 0). Alone = a fixed monthly budget.' },
        clear_monthly_budget: { type: 'boolean', description: 'true removes the monthly budget (both ends).' },
        msa_url: { type: 'string' },
        sow_url: { type: 'string' },
        twist_channel_url: { type: 'string', description: "http(s) URL of the project's Twist channel." },
        notion_homepage_url: { type: 'string', description: "http(s) URL of the project's Notion homepage." },
      },
      required: %w[project_tracker_id]
    )
    annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true)

    def self.call(project_tracker_id:, name: nil, budget_low_end: nil, budget_high_end: nil,
                  monthly_budget_low_end: nil, monthly_budget_high_end: nil, clear_monthly_budget: false,
                  msa_url: nil, sow_url: nil, twist_channel_url: nil, notion_homepage_url: nil,
                  server_context:)
      ptid = WriteValidation.integer!("project_tracker_id", project_tracker_id)
      tracker = ProjectTracker.find(ptid)
      before = ProvisioningSerializers.tracker_json(tracker)
      WriteGuard.check!
      tracker.update_details!(name: name, budget_low_end: budget_low_end,
                              budget_high_end: budget_high_end, msa_url: msa_url, sow_url: sow_url,
                              monthly_budget_low_end: monthly_budget_low_end,
                              monthly_budget_high_end: monthly_budget_high_end,
                              clear_monthly_budget: clear_monthly_budget == true,
                              twist_channel_url: twist_channel_url,
                              notion_homepage_url: notion_homepage_url)
      Responses.ok({ before: before, after: ProvisioningSerializers.tracker_json(tracker.reload) })
    rescue ArgumentError, WriteGuard::CapExceeded => e
      Responses.error(e.message)
    rescue ActiveRecord::RecordNotFound
      Responses.error("project_tracker #{project_tracker_id} not found")
    rescue ActiveRecord::RecordInvalid => e
      Responses.error(e.record.errors.full_messages.join('; '))
    rescue StandardError => e
      Rails.logger.warn("[Mcp::UpdateProjectTrackerTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error("update_project_tracker failed; the error was logged")
    end
  end
end
