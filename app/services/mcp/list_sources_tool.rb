module Mcp
  class ListSourcesTool < MCP::Tool
    tool_name 'list_sources'
    description 'List ingested sources and their last-sync freshness.'
    input_schema(properties: {})
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(server_context:)
      payload = SourceSync.all.map { |s| { source: s.source, last_run_at: s.last_run_at, status: s.status, stats: s.stats } }
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
