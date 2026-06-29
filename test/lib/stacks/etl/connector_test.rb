require 'test_helper'

class Stacks::Etl::ConnectorTest < ActiveSupport::TestCase
  class FakeConnector < Stacks::Etl::Connector
    def initialize(docs, exclusion: [:not_excluded, :none])
      @docs = docs; @exclusion = exclusion
    end
    def source = :meet
    def extract(since:) = @docs
    def exclusion_for(_n) = @exclusion
  end

  def normalized(external_id:, hash:)
    {
      external_id: external_id, title: 'T', url: 'http://x', occurred_at: Time.utc(2026, 1, 1),
      content_hash: hash,
      contacts: [{ email: 'a@x.co', name: 'A', role: 'participant' }],
      segments: [{ speaker_name: 'A', speaker_email: 'a@x.co', text: 'we decided to ship', started_at: Time.utc(2026, 1, 1) }],
      raw_metadata: {}, build_source_record: ->(_doc) { nil }
    }
  end

  setup do
    Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [[0.5] * 1024], total_tokens: 1)
  end

  test 'ingests a corpus-eligible document: chunks, embeds, links contacts' do
    FakeConnector.new([normalized(external_id: 'm1', hash: 'h1')]).run
    doc = Document.find_by!(source: :meet, external_id: 'm1')
    assert_equal 1, doc.chunks.count
    assert_equal 1, Embedding.where(owner: doc.chunks.first).count
    assert_equal ['a@x.co'], doc.document_contacts.pluck(:email)
    assert doc.not_excluded?
  end

  test 'unchanged content_hash skips re-chunking' do
    conn = FakeConnector.new([normalized(external_id: 'm1', hash: 'h1')])
    conn.run
    Stacks::Etl::Chunker.expects(:call).never
    FakeConnector.new([normalized(external_id: 'm1', hash: 'h1')]).run
  end

  test 'excluded document gets no chunks or embeddings' do
    FakeConnector.new([normalized(external_id: 'm2', hash: 'h2')], exclusion: [:auto_excluded, :one_on_one]).run
    doc = Document.find_by!(external_id: 'm2')
    assert doc.auto_excluded?
    assert_equal 0, doc.chunks.count
  end

  test 'a doc reclassified eligible -> excluded loses its existing chunks' do
    FakeConnector.new([normalized(external_id: 'm4', hash: 'h4')]).run
    doc = Document.find_by!(external_id: 'm4')
    assert_equal 1, doc.chunks.count

    FakeConnector.new([normalized(external_id: 'm4', hash: 'h4b')], exclusion: [:auto_excluded, :one_on_one]).run
    doc.reload
    assert doc.auto_excluded?
    assert_equal 0, doc.chunks.count
    assert_equal 0, Embedding.where(owner_type: 'Chunk', owner_id: Chunk.where(document_id: doc.id).select(:id)).count
  end

  test 'human-locked exclusion is not overwritten by the classifier' do
    FakeConnector.new([normalized(external_id: 'm3', hash: 'h3')]).run
    Document.find_by!(external_id: 'm3').update!(excluded: :manually_excluded, excluded_reason: :manual)
    FakeConnector.new([normalized(external_id: 'm3', hash: 'h3b')], exclusion: [:not_excluded, :none]).run
    assert Document.find_by!(external_id: 'm3').manually_excluded?
  end

  test 'advances the watermark' do
    sync = FakeConnector.new([normalized(external_id: 'm1', hash: 'h1')]).run
    assert_equal 'success', sync.status
    assert_equal 1, sync.stats['documents']
  end

  test 'unchanged content_hash does NOT re-invoke build_source_record' do
    call_count = 0
    doc_with_counter = normalized(external_id: 'bsr1', hash: 'hbsr').merge(
      build_source_record: ->(_doc) { call_count += 1; nil }
    )
    FakeConnector.new([doc_with_counter]).run
    assert_equal 1, call_count, 'build_source_record should be called on first ingest'
    FakeConnector.new([doc_with_counter]).run
    assert_equal 1, call_count, 'build_source_record should NOT be called again for unchanged doc'
  end
end
