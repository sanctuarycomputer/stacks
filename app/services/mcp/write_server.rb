unless defined?(MCP::Server)
  mcp_gem = Gem.loaded_specs['mcp']
  raise "mcp gem not found in Gem.loaded_specs; cannot resolve MCP::Server" unless mcp_gem
  require File.join(mcp_gem.gem_dir, 'lib', 'mcp', 'server')
end

module Mcp
  # The WRITE surface (/api/mcp/write). Deliberately disjoint from
  # Mcp::Server (/api/mcp), which stays read-only forever. Only
  # projection-plane tools exist here — actuals, rates, and money have no
  # tools, so no composition can reach them.
  class WriteServer
    TOOLS = [
      Mcp::CreateAssignmentTool,
      Mcp::DeleteAssignmentTool,
      Mcp::CreateTentativeProjectTool,
      Mcp::ArchiveProjectTool,
      Mcp::CreatePlaceholderTool,
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
