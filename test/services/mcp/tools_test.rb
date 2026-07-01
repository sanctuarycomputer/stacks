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

  def ids_for(resp)
    JSON.parse(resp.content.first[:text]).map { |d| d['id'] }
  end
end
