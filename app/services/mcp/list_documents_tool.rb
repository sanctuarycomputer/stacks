module Mcp
  class ListDocumentsTool < MCP::Tool
    tool_name 'list_documents'
    description 'List corpus-eligible documents (newest first), optionally filtered by source and occurred_at range, with offset pagination.'
    input_schema(properties: {
      source: { type: 'string' },
      occurred_after: { type: 'string', description: 'ISO8601 lower bound on occurred_at (inclusive)' },
      occurred_before: { type: 'string', description: 'ISO8601 upper bound on occurred_at (inclusive)' },
      limit: { type: 'integer' },
      offset: { type: 'integer', description: 'Number of documents to skip, for pagination' }
    })
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(source: nil, occurred_after: nil, occurred_before: nil, limit: 50, offset: 0, server_context:)
      scope = Document.corpus_eligible
      scope = scope.where(source: Document.sources[source]) if source
      range = Mcp::DateRange.parse(occurred_after, occurred_before)
      scope = scope.where(occurred_at: range) if range
      scope = scope.order(occurred_at: :desc).offset(offset).limit(limit)
      payload = scope.map { |d| { id: d.id, title: d.title, source: d.source, occurred_at: d.occurred_at } }
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
