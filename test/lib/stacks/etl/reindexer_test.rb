require 'test_helper'

class Stacks::Etl::ReindexerTest < ActiveSupport::TestCase
  setup do
    Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [Array.new(1024, 0.5), Array.new(1024, 0.5)])
  end

  def doc_with_stored_segments(excluded:)
    doc = Document.create!(source: :meet, external_id: 'm1', excluded: excluded)
    meeting = Meeting.create!(meet_conference_record_id: 'conferenceRecords/r1', meet_source: :meet_api)
    doc.update!(source_record: meeting)
    meeting.segments.create!(position: 0, speaker_name: 'A', text: 'we shipped the gateway')
    meeting.segments.create!(position: 1, speaker_name: 'B', text: 'great work everyone')
    doc
  end

  test 'does nothing for a still-excluded document' do
    doc = doc_with_stored_segments(excluded: :auto_excluded)
    refute Stacks::Etl::Reindexer.call(doc)
    assert_equal 0, doc.chunks.count
  end

  test 'indexes a re-included document from its stored segments (no re-fetch)' do
    doc = doc_with_stored_segments(excluded: :manually_included)
    assert_equal 0, doc.chunks.count
    assert Stacks::Etl::Reindexer.call(doc)
    assert_equal 2, doc.chunks.count
    assert_equal 2, Embedding.where(owner_type: 'Chunk', owner_id: doc.chunks.select(:id)).count
    assert_includes doc.chunks.pluck(:content), 'we shipped the gateway'
  end

  test 'returns false when there are no stored segments' do
    doc = Document.create!(source: :meet, external_id: 'm3', excluded: :manually_included)
    refute Stacks::Etl::Reindexer.call(doc)
  end
end
