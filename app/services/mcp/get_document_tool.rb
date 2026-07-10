module Mcp
  class GetDocumentTool < MCP::Tool
    tool_name 'get_document'
    description 'Fetch one corpus-eligible document with its transcript segments, full text, and meeting key.'
    input_schema(properties: { id: { type: 'integer' } }, required: ['id'])
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(id:, server_context:)
      doc = Document.corpus_eligible.find_by(id: id)
      return Responses.error('Document not found') unless doc

      meeting = doc.source_record
      is_meeting = meeting.is_a?(Meeting)
      segments = is_meeting ? meeting.segments.order(:position).map { |s| { speaker: s.speaker_name, text: s.text } } : []
      # `body` is the document's own text (its chunks). For a transcript doc this is
      # redundant with `segments`; it is intentional so a Gemini note (which has no
      # segments) is still readable. Callers prefer `segments` for transcripts, `body` for notes.
      body = doc.chunks.order(:position).pluck(:content).join("\n")
      meeting_key = is_meeting ? meeting.id : nil
      # google_groups: expose the RFC822 root Message-ID (external_id) so an observing agent can
      # build the precise Gmail deep link (rfc822msgid:<id>). url already carries the group.
      extra = doc.google_groups? ? { root_message_id: doc.external_id } : {}
      Responses.ok({ id: doc.id, title: doc.title, url: doc.url, occurred_at: doc.occurred_at,
                     source: doc.source, meeting_key: meeting_key, segments: segments, body: body }
                   .merge(extra))
    end
  end
end
