require 'test_helper'

class Stacks::Etl::ChunkerTest < ActiveSupport::TestCase
  test 'one chunk per speaker turn, carrying speaker + timestamp' do
    segs = [
      { speaker_name: 'A', speaker_email: 'a@x.co', text: 'hello there', started_at: Time.utc(2026, 1, 1, 9) },
      { speaker_name: 'B', speaker_email: 'b@x.co', text: 'general kenobi', started_at: Time.utc(2026, 1, 1, 9, 1) }
    ]
    chunks = Stacks::Etl::Chunker.call(segments: segs)
    assert_equal 2, chunks.size
    assert_equal 'hello there', chunks[0][:content]
    assert_equal 'A', chunks[0][:speaker_name]
    assert_equal 'b@x.co', chunks[1][:speaker_email]
  end

  test 'splits an over-long turn into overlapping chunks' do
    long = (1..600).map { |i| "w#{i}" }.join(' ')
    chunks = Stacks::Etl::Chunker.call(segments: [{ speaker_name: 'A', speaker_email: 'a@x.co', text: long, started_at: Time.now }])
    assert_operator chunks.size, :>=, 2
    assert chunks.all? { |c| c[:content].split.size <= Stacks::Etl::Chunker::MAX_WORDS }
  end

  test 'coalesces consecutive same-speaker segments into one chunk (Meet-API tiny utterances)' do
    segs = [
      { speaker_name: 'A', speaker_email: 'a@x.co', text: 'one', started_at: Time.utc(2026, 1, 1, 9) },
      { speaker_name: 'A', speaker_email: 'a@x.co', text: 'two', started_at: Time.utc(2026, 1, 1, 9, 0, 5) },
      { speaker_name: 'B', speaker_email: 'b@x.co', text: 'three', started_at: Time.utc(2026, 1, 1, 9, 1) },
      { speaker_name: 'A', speaker_email: 'a@x.co', text: 'four', started_at: Time.utc(2026, 1, 1, 9, 2) }
    ]
    chunks = Stacks::Etl::Chunker.call(segments: segs)
    # A's first two utterances merge; B breaks the run; A's later turn is its own chunk.
    assert_equal ['one two', 'three', 'four'], chunks.map { |c| c[:content] }
    assert_equal %w[A B A], chunks.map { |c| c[:speaker_name] }
    assert_equal Time.utc(2026, 1, 1, 9), chunks.first[:occurred_at] # first turn's timestamp
  end

  test 'does not emit a trailing near-duplicate chunk' do
    # 720 words: the 2nd window reaches the end, so exactly 2 chunks (the old sliding
    # loop emitted a 3rd window that was ~entirely overlap).
    long = (1..720).map { |i| "w#{i}" }.join(' ')
    chunks = Stacks::Etl::Chunker.call(segments: [{ speaker_name: 'A', speaker_email: 'a@x.co', text: long, started_at: Time.now }])
    assert_equal 2, chunks.size
    assert_equal 'w720', chunks.last[:content].split.last
  end
end
