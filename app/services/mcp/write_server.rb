unless defined?(MCP::Server)
  mcp_gem = Gem.loaded_specs['mcp']
  raise "mcp gem not found in Gem.loaded_specs; cannot resolve MCP::Server" unless mcp_gem
  require File.join(mcp_gem.gem_dir, 'lib', 'mcp', 'server')
end

module Mcp
  # The WRITE surface (/api/mcp/write). Deliberately disjoint from
  # Mcp::Server (/api/mcp), which stays read-only forever. Only
  # projection-plane and provisioning tools exist here. Actuals & billing
  # money (what a contributor is paid / a client is invoiced) have no tools,
  # so no composition can reach them; a project's p/h rate-card tag is
  # provisioning setup, not a money-actual.
  class WriteServer
    TOOLS = [
      Mcp::CreateAssignmentTool,
      Mcp::DeleteAssignmentTool,
      Mcp::CreateTentativeProjectTool,
      Mcp::ArchiveProjectTool,
      Mcp::CreatePlaceholderTool,
      Mcp::EnsureProjectTrackerTool,
      Mcp::UpdateProjectTrackerTool,
      Mcp::EnsureWorkstreamTool,
      Mcp::CreateRecurringAssignmentTool,
      Mcp::ManageRecurringAssignmentTool,
      Mcp::RemoveWorkstreamRateTool,
      Mcp::SetProjectTrackerWorkCompletedAtTool,
      Mcp::SetProjectTrackerRoleAssigneeTool,
    ].freeze

    # Each write tool needs one scope (ApiToken::SCOPES). A caller only ever SEES the tools its scopes allow:
    # tools/list lists them, and a call to any other tool is "Tool not found".
    TOOL_SCOPES = {
      "create_assignment" => "mcp:write:resourcing",
      "delete_assignment" => "mcp:write:resourcing",
      "create_placeholder" => "mcp:write:resourcing",
      "create_recurring_assignment" => "mcp:write:resourcing",
      "manage_recurring_assignment" => "mcp:write:resourcing",
      "create_tentative_project" => "mcp:write:projects",
      "archive_project" => "mcp:write:projects",
      "ensure_project_tracker" => "mcp:write:trackers",
      "update_project_tracker" => "mcp:write:trackers",
      "ensure_workstream" => "mcp:write:trackers",
      "remove_workstream_rate" => "mcp:write:trackers",
      "set_project_tracker_work_completed_at" => "mcp:write:trackers",
      "set_project_tracker_role_assignee" => "mcp:write:trackers",
    }.freeze
    WRITE_SCOPES = TOOL_SCOPES.values.uniq.freeze

    def self.tools_for(scopes)
      TOOLS.select { |t| scopes.include?(TOOL_SCOPES.fetch(t.name_value)) }
    end

    # scopes is required: a forgotten argument must not fail open to every write tool.
    def self.build(scopes:)
      MCP::Server.new(
        name: "stacks-write",
        version: "1.0.0",
        tools: tools_for(scopes)
      )
    end
  end
end
