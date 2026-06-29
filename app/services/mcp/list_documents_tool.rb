module Mcp
  class ListDocumentsTool < MCP::Tool
    description 'List corpus-eligible documents, optionally filtered by source.'
    input_schema(properties: { source: { type: 'string' }, limit: { type: 'integer' } })
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(source: nil, limit: 50, server_context:)
      scope = Document.corpus_eligible.order(occurred_at: :desc).limit(limit)
      scope = scope.where(source: Document.sources[source]) if source
      payload = scope.map { |d| { id: d.id, title: d.title, source: d.source, occurred_at: d.occurred_at } }
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
