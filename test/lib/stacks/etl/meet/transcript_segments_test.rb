require "test_helper"

class Stacks::Etl::Meet::TranscriptSegmentsTest < ActiveSupport::TestCase
  # A tiny host so we can call the module's instance methods.
  class Host
    include Stacks::Etl::Meet::TranscriptSegments
  end
  def parser = Host.new

  test "parses Name: text speaker lines, ignoring non-speaker lines" do
    segs = parser.parse_segments("Drew Smith: we should ship\nhttps://x was shared\n10:30 break\nHugh: agreed")
    assert_equal ["Drew Smith", "Hugh"], segs.map { |s| s[:speaker_name] }
    assert_equal "we should ship", segs.first[:text]
  end

  test "a mid-sentence colon does not spawn a phantom speaker (1:1 count honesty)" do
    segs = parser.parse_segments("Alice: I think the answer is: yes\nBob: agreed")
    assert_equal ["Alice", "Bob"], segs.map { |s| s[:speaker_name] }
  end

  test "recognizes Meet anonymous 'Speaker N' labels" do
    segs = parser.parse_segments("Speaker 1: hello\nSpeaker 2: hi\nAlice: welcome")
    assert_equal ["Speaker 1", "Speaker 2", "Alice"], segs.map { |s| s[:speaker_name] }
  end

  test "distinct_speaker_count counts unique speakers" do
    segs = parser.parse_segments("Alice: hi\nBob: yo\nAlice: bye")
    assert_equal 2, parser.distinct_speaker_count(segs)
  end
end
