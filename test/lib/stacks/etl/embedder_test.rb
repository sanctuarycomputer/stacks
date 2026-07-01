require 'test_helper'

class Stacks::Etl::EmbedderTest < ActiveSupport::TestCase
  test 'embeds a batch of documents into vectors (no prefix)' do
    captured = nil
    Stacks::Etl::Embedder.stubs(:pipeline).returns(->(arr) { captured = arr; arr.map { [0.1] * 1024 } })
    out = Stacks::Etl::Embedder.embed(%w[alpha beta])
    assert_equal %w[alpha beta], captured
    assert_equal [[0.1] * 1024, [0.1] * 1024], out[:vectors]
  end

  test 'prepends the query prefix for the query input_type' do
    captured = nil
    Stacks::Etl::Embedder.stubs(:pipeline).returns(->(arr) { captured = arr; arr.map { [0.0] * 1024 } })
    Stacks::Etl::Embedder.embed(['gateway'], input_type: 'query')
    assert_equal ['Represent this sentence for searching relevant passages: gateway'], captured
  end

  test 'normalizes a single-string return into an array of vectors' do
    Stacks::Etl::Embedder.stubs(:pipeline).returns(->(_arr) { [0.2] * 1024 })
    out = Stacks::Etl::Embedder.embed('solo')
    assert_equal [[0.2] * 1024], out[:vectors]
  end
end
