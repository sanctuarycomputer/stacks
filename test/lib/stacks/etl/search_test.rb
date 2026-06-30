require 'test_helper'

class Stacks::Etl::SearchTest < ActiveSupport::TestCase
  setup do
    @doc = Document.create!(source: :meet, external_id: 'd1', occurred_at: Time.utc(2026, 1, 1), excluded: :not_excluded)
    @hit = Chunk.create!(document: @doc, position: 0, content: 'we decided to ship the gateway redesign', source: :meet)
    @miss = Chunk.create!(document: @doc, position: 1, content: 'lunch on friday', source: :meet)
    excluded_doc = Document.create!(source: :meet, external_id: 'd2', excluded: :auto_excluded)
    @excluded = Chunk.create!(document: excluded_doc, position: 0, content: 'gateway secret', source: :meet)
  end

  test 'keyword mode finds matches and excludes walled-off chunks' do
    results = Stacks::Etl::Search.call(query: 'gateway', mode: :keyword)
    ids = results.map { |r| r[:chunk].id }
    assert_includes ids, @hit.id
    refute_includes ids, @excluded.id
    refute_includes ids, @miss.id
  end

  test 'a contact filter with an unknown email returns nothing (not unattributed chunks)' do
    results = Stacks::Etl::Search.call(query: 'gateway', mode: :keyword, contact: 'stranger@nowhere.com')
    assert_empty results
  end

  test 'semantic mode embeds the query, ranks by neighbor distance, and walls off excluded chunks' do
    skip_without_pgvector # creates Embedding records + runs a neighbor (vector) query
    Embedding.create!(owner: @hit, model: Stacks::Etl::Embedder::MODEL, embedding: Array.new(1024) { 0.0 }.tap { |v| v[0] = 1.0 })
    Embedding.create!(owner: @miss, model: Stacks::Etl::Embedder::MODEL, embedding: Array.new(1024) { 0.0 }.tap { |v| v[1] = 1.0 })
    # The excluded chunk's embedding is IDENTICAL to the query vector — if the corpus
    # wall leaked in semantic mode it would rank first.
    Embedding.create!(owner: @excluded, model: Stacks::Etl::Embedder::MODEL, embedding: Array.new(1024) { 0.0 }.tap { |v| v[0] = 1.0 })
    Stacks::Etl::Embedder.expects(:embed).with(['gateway'], input_type: 'query').returns(vectors: [Array.new(1024) { 0.0 }.tap { |v| v[0] = 1.0 }], total_tokens: 1)

    results = Stacks::Etl::Search.call(query: 'gateway', mode: :semantic)
    ids = results.map { |r| r[:chunk].id }
    assert_equal @hit.id, results.first[:chunk].id
    refute_includes ids, @excluded.id
  end
end
