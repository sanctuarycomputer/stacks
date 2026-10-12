module Mcp
  class ListDocumentsTool < MCP::Tool
    tool_name 'list_documents'
    description 'List corpus-eligible documents (newest first), optionally filtered by source and occurred_at range, with offset pagination. ' \
                'project_tracker_ids lists the project tracker(s) a meeting document was matched to (empty when none, or not a meeting).'
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
      docs = scope.to_a
      # One query for the page: a transcript and its notes share their Meeting's match.
      meeting_ids = docs.select { |d| d.source_record_type == 'Meeting' }.map(&:source_record_id)
      tracker_ids = Meeting.project_tracker_ids_by_meeting(meeting_ids)
      payload = docs.map do |d|
        matched = d.source_record_type == 'Meeting' ? tracker_ids.fetch(d.source_record_id, []) : []
        { id: d.id, title: d.title, source: d.source, occurred_at: d.occurred_at, project_tracker_ids: matched }
      end
      Responses.ok(payload)
    end
  end
end
