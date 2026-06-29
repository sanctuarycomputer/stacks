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
end
