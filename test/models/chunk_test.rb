require 'test_helper'

class ChunkTest < ActiveSupport::TestCase
  setup { @doc = Document.create!(source: :meet, external_id: 'd1') }

  test 'keyword_search matches on generated tsvector' do
    hit  = Chunk.create!(document: @doc, position: 0, content: 'We decided to ship the gateway redesign', source: :meet)
    Chunk.create!(document: @doc, position: 1, content: 'Lunch plans for friday', source: :meet)
    assert_includes Chunk.keyword_search('gateway').to_a, hit
    assert_equal 1, Chunk.keyword_search('gateway').count
  end
end
