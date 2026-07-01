module Mcp
  class SearchTool < MCP::Tool
    tool_name 'search'
    description 'Search org meeting transcripts (and future sources) by keyword, semantic, or hybrid.'
    input_schema(
      properties: {
        query: { type: 'string' },
        mode: { type: 'string', enum: %w[keyword semantic hybrid] },
        source: { type: 'string' },
        contact: { type: 'string' },
        limit: { type: 'integer' }
      },
      required: ['query']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(query:, mode: 'hybrid', source: nil, contact: nil, limit: 20, server_context:)
      results = Stacks::Etl::Search.call(query: query, mode: mode.to_sym, source: source, contact: contact, limit: limit)
      payload = results.map do |r|
        { document_id: r[:document].id, title: r[:document].title, occurred_at: r[:document].occurred_at,
          speaker: r[:chunk].speaker_name, text: r[:chunk].content }
      end
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
