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
        occurred_after: { type: 'string', description: 'ISO8601 lower bound on occurred_at (inclusive)' },
        occurred_before: { type: 'string', description: 'ISO8601 upper bound on occurred_at (inclusive)' },
        limit: { type: 'integer' },
        offset: { type: 'integer', description: 'Number of results to skip, for pagination' }
      },
      required: ['query']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(query:, mode: 'hybrid', source: nil, contact: nil, occurred_after: nil, occurred_before: nil, limit: 20, offset: 0, server_context:)
      results = Stacks::Etl::Search.call(
        query: query, mode: mode.to_sym, source: source, contact: contact,
        date_range: Mcp::DateRange.parse(occurred_after, occurred_before), limit: limit, offset: offset
      )
      payload = results.map do |r|
        { document_id: r[:document].id, title: r[:document].title, occurred_at: r[:document].occurred_at,
          speaker: r[:chunk].speaker_name, text: r[:chunk].content }
      end
      Responses.ok(payload)
    end
  end
end
