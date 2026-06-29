require 'test_helper'

class EmbeddingTest < ActiveSupport::TestCase
  setup do
    @doc = Document.create!(source: :meet, external_id: 'd1')
    @chunk = Chunk.create!(document: @doc, position: 0, content: 'hello', source: :meet)
  end

  test 'stores a vector and finds nearest neighbors by cosine' do
    near = Embedding.create!(owner: @chunk, model: 'mxbai-embed-large-v1', embedding: Array.new(1024) { 0.0 }.tap { |v| v[0] = 1.0 })
    other = Chunk.create!(document: @doc, position: 1, content: 'bye', source: :meet)
    Embedding.create!(owner: other, model: 'mxbai-embed-large-v1', embedding: Array.new(1024) { 0.0 }.tap { |v| v[1] = 1.0 })

    query = Array.new(1024) { 0.0 }.tap { |v| v[0] = 1.0 }
    result = Embedding.where(model: 'mxbai-embed-large-v1').nearest_neighbors(:embedding, query, distance: 'cosine').first
    assert_equal near.id, result.id
  end

  test 'one embedding per owner per model' do
    Embedding.create!(owner: @chunk, model: 'mxbai-embed-large-v1', embedding: Array.new(1024, 0.0))
    assert_raises(ActiveRecord::RecordNotUnique) do
      Embedding.create!(owner: @chunk, model: 'mxbai-embed-large-v1', embedding: Array.new(1024, 0.0))
    end
  end
end
