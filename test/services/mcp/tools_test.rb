require 'test_helper'

class Mcp::ToolsTest < ActiveSupport::TestCase
  setup do
    @doc = Document.create!(source: :meet, external_id: 'd1', title: 'Gateway', excluded: :not_excluded)
    @chunk = Chunk.create!(document: @doc, position: 0, content: 'we decided to ship the gateway', source: :meet)
    @excluded = Document.create!(source: :meet, external_id: 'd2', title: 'Secret 1:1', excluded: :auto_excluded)
  end

  test 'search tool returns hits as json text' do
    resp = Mcp::SearchTool.call(query: 'gateway', mode: 'keyword', server_context: {})
    text = resp.content.first[:text]
    assert_includes text, 'gateway'
  end

  test 'get_document refuses an excluded document' do
    resp = Mcp::GetDocumentTool.call(id: @excluded.id, server_context: {})
    assert_includes resp.content.first[:text].downcase, 'not found'
  end

  test 'list_documents omits excluded documents (privacy wall)' do
    resp = Mcp::ListDocumentsTool.call(server_context: {})
    payload = JSON.parse(resp.content.first[:text])
    ids = payload.map { |d| d['id'] }
    assert_includes ids, @doc.id
    refute_includes ids, @excluded.id
  end

  test 'list_documents filters by occurred_at range and paginates with offset' do
    a = Document.create!(source: :meet, external_id: 'a', title: 'Recent A', excluded: :not_excluded, occurred_at: Time.utc(2026, 6, 3))
    b = Document.create!(source: :meet, external_id: 'b', title: 'Recent B', excluded: :not_excluded, occurred_at: Time.utc(2026, 6, 2))
    _old = Document.create!(source: :meet, external_id: 'c', title: 'Old', excluded: :not_excluded, occurred_at: Time.utc(2025, 1, 1))

    ranged = ids_for(Mcp::ListDocumentsTool.call(occurred_after: '2026-06-01', server_context: {}))
    assert_equal [a.id, b.id], ranged, 'only in-range docs, newest first'

    page2 = ids_for(Mcp::ListDocumentsTool.call(occurred_after: '2026-06-01', limit: 1, offset: 1, server_context: {}))
    assert_equal [b.id], page2, 'offset skips the first (newest) in-range doc'
  end

  test "list_documents can filter to gemini_notes and hides excluded notes" do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/z")
    note = Document.create!(source: :gemini_notes, external_id: "gn", title: "Roadmap notes", excluded: :not_excluded, source_record: m)
    Document.create!(source: :gemini_notes, external_id: "gn2", title: "1:1 notes", excluded: :auto_excluded, source_record: m)

    resp = Mcp::ListDocumentsTool.call(source: "gemini_notes", server_context: {})
    ids = JSON.parse(resp.content.first[:text]).map { |d| d["id"] }
    assert_equal [note.id], ids
  end

  test 'get_document returns body joined from the doc chunks in position order' do
    # @doc already has a position-0 chunk from setup; add a later one out of insertion order.
    Chunk.create!(document: @doc, position: 2, content: 'and we set the launch date', source: :meet)
    Chunk.create!(document: @doc, position: 1, content: 'then we picked the rollout plan', source: :meet)

    payload = JSON.parse(Mcp::GetDocumentTool.call(id: @doc.id, server_context: {}).content.first[:text])
    assert_equal(
      "we decided to ship the gateway\nthen we picked the rollout plan\nand we set the launch date",
      payload['body']
    )
  end

  test 'get_document returns meeting_key for a meeting-backed doc and nil for a standalone doc' do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: 'cr/gd-1')
    note = Document.create!(source: :gemini_notes, external_id: 'gd-note', title: 'Roadmap notes',
                            excluded: :not_excluded, source_record: m)
    Chunk.create!(document: note, position: 0, content: 'summary: shipped the gateway', source: :meet)

    linked = JSON.parse(Mcp::GetDocumentTool.call(id: note.id, server_context: {}).content.first[:text])
    assert_equal m.id, linked['meeting_key']
    assert_equal 'summary: shipped the gateway', linked['body']

    standalone = JSON.parse(Mcp::GetDocumentTool.call(id: @doc.id, server_context: {}).content.first[:text])
    assert_nil standalone['meeting_key']
  end

  def ids_for(resp)
    JSON.parse(resp.content.first[:text]).map { |d| d['id'] }
  end
end
