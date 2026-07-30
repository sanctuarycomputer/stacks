# The classic autoloader adds app/services to $LOAD_PATH before the mcp gem's lib
# directory.  Ruby's native `autoload :Server, "mcp/server"` (set up by the gem)
# would therefore find THIS file instead of the gem's lib/mcp/server.rb, leaving
# MCP::Server undefined.  We pre-load the gem's server via its absolute path so
# MCP::Server is defined before we define Mcp::Server.
unless defined?(MCP::Server)
  mcp_gem = Gem.loaded_specs['mcp']
  raise "mcp gem not found in Gem.loaded_specs; cannot resolve MCP::Server" unless mcp_gem
  require File.join(mcp_gem.gem_dir, 'lib', 'mcp', 'server')
end

module Mcp
  class Server
    TOOLS = [
      Mcp::SearchTool,
      Mcp::ListDocumentsTool,
      Mcp::ListSourcesTool,
      Mcp::GetDocumentTool,
      Mcp::GetArAgingTool,
      Mcp::ListOverdueInvoicesTool,
      Mcp::ListOpenAdminTasksTool,
      Mcp::ListProjectsAtRiskTool,
      Mcp::GetStudioHealthTool,
      Mcp::GetResourcingProjectionsTool,
    ].freeze

    def self.build
      MCP::Server.new(
        name: "stacks",
        version: "1.0.0",
        tools: TOOLS
      )
    end
  end
end
