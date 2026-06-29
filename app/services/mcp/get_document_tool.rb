module Mcp
  class GetDocumentTool < MCP::Tool
    description 'Fetch one corpus-eligible document with its transcript segments.'
    input_schema(properties: { id: { type: 'integer' } }, required: ['id'])
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(id:, server_context:)
      doc = Document.corpus_eligible.find_by(id: id)
      return MCP::Tool::Response.new([{ type: 'text', text: 'Document not found' }]) unless doc

      meeting = doc.source_record
      segments = meeting.is_a?(Meeting) ? meeting.segments.order(:position).map { |s| { speaker: s.speaker_name, text: s.text } } : []
      MCP::Tool::Response.new([{ type: 'text', text: { id: doc.id, title: doc.title, url: doc.url, occurred_at: doc.occurred_at, segments: segments }.to_json }])
    end
  end
end
