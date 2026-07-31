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
    ].freeze

    def self.build
      MCP::Server.new(
        name: "stacks-write",
        version: "1.0.0",
        tools: TOOLS
      )
    end
  end
end
