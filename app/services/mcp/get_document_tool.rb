module Mcp
  class GetDocumentTool < MCP::Tool
    tool_name 'get_document'
    description 'Fetch one corpus-eligible document with its transcript segments, full text, and meeting key. ' \
                'project_tracker_ids lists the project tracker(s) its meeting was matched to (empty when none, or not a meeting). ' \
                'notion_project_ids lists the Notion project page ids of every tracker the document is linked to: the trackers its meeting was matched to, ' \
                'or for a ships@ email the trackers of its weekly ship. De-duplicated and sorted; empty when it is linked to no tracker or its trackers name no Notion project.'
    input_schema(properties: { id: { type: 'integer' } }, required: ['id'])
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(id:, server_context:)
      doc = Document.corpus_eligible.find_by(id: id)
      return Responses.error('Document not found') unless doc

      meeting = doc.source_record
      is_meeting = meeting.is_a?(Meeting)
      # Segments belong to the TRANSCRIPT. A notes doc shares its transcript's Meeting row, so
      # reading meeting.segments for notes would hand back the transcript's text even when the
      # transcript itself is walled off. Only the transcript document returns them.
      segments = is_meeting && doc.meet? ? meeting.segments.order(:position).map { |s| { speaker: s.speaker_name, text: s.text } } : []
      # `body` is the document's own text (its chunks). For a transcript doc this is
      # redundant with `segments`; it is intentional so a Gemini note (which has no
      # segments) is still readable. Callers prefer `segments` for transcripts, `body` for notes.
      body = doc.chunks.order(:position).pluck(:content).join("\n")
      meeting_key = is_meeting ? meeting.id : nil
      # Which project tracker(s) the meeting was about, and the Notion projects of
      # every tracker the document is linked to: ids only. The sweep's reason and
      # confidence stay in Stacks.
      projects = Mcp::DocumentProjects.for([doc]).fetch(doc.id)
      # google_groups: expose the RFC822 root Message-ID (external_id) so an observing agent can
      # build the precise Gmail deep link (rfc822msgid:<id>). url already carries the group.
      extra = doc.google_groups? ? { root_message_id: doc.external_id } : {}
      Responses.ok({ id: doc.id, title: doc.title, url: doc.url, occurred_at: doc.occurred_at,
                     source: doc.source, meeting_key: meeting_key, project_tracker_ids: projects[:project_tracker_ids],
                     notion_project_ids: projects[:notion_project_ids], segments: segments, body: body }
                   .merge(extra))
    end
  end
end
