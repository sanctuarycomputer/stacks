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

  test 'warm! forces a query embed through the pipeline and returns true' do
    captured = nil
    Stacks::Etl::Embedder.stubs(:pipeline).returns(->(arr) { captured = arr; arr.map { [0.0] * 1024 } })
    assert_equal true, Stacks::Etl::Embedder.warm!
    # It runs a throwaway QUERY embed so the whole cold path (prefix + inference) is exercised.
    assert_equal 1, captured.length
    assert captured.first.start_with?(Stacks::Etl::Embedder::QUERY_PREFIX)
  end

  test 'warm! swallows and reports pipeline build failures without raising' do
    Stacks::Etl::Embedder.stubs(:pipeline).raises(RuntimeError.new('model download failed'))
    assert_nothing_raised { assert_equal false, Stacks::Etl::Embedder.warm! }
  end

  test 'reset! drops the memoized pipeline so it is rebuilt on next use' do
    Informers.expects(:pipeline).twice.returns(->(arr) { arr.map { [0.1] * 1024 } })
    Stacks::Etl::Embedder.reset!
    Stacks::Etl::Embedder.pipeline
    Stacks::Etl::Embedder.pipeline # memoized -> still one build
    Stacks::Etl::Embedder.reset!
    Stacks::Etl::Embedder.pipeline # rebuilt -> second build
  ensure
    Stacks::Etl::Embedder.reset!
  end
end
