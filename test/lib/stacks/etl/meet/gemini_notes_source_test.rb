require "test_helper"
class Stacks::Etl::Meet::GeminiNotesSourceTest < ActiveSupport::TestCase
  SAMPLE = <<~TXT
    Notes

    ## Sync Title

    Invited [Ayaka Takao](mailto:Ayaka@Index-Space.org) [Hugh Francis](mailto:hugh@sanctuary.computer) [Room](mailto:room@resource.calendar.google.com)

    Meeting records [Transcript](https://docs.google.com/document/d/TRANSCRIPT_ID_123/edit?usp=drive_web)

    ### Summary
    We decided to ship the gateway redesign.

    ### Next steps
    - [Hugh Francis] Finish Slides: Complete the case study slides.
  TXT

  def src = Stacks::Etl::Meet::GeminiNotesSource.allocate

  test "extracts the transcript doc id from the Transcript link" do
    assert_equal "TRANSCRIPT_ID_123", src.send(:transcript_doc_id_from, SAMPLE)
    assert_nil src.send(:transcript_doc_id_from, "no link here")
  end

  test "extracts invited emails (lowercased), skipping room resources" do
    assert_equal ["ayaka@index-space.org", "hugh@sanctuary.computer"],
                 src.send(:invited_emails_from, SAMPLE)
  end

  test "body segments carry the notes text with the meeting time and no speaker" do
    at = Time.utc(2026, 6, 30, 15)
    segs = src.send(:body_segments, SAMPLE, occurred_at: at)
    assert segs.any?
    joined = segs.map { |s| s[:text] }.join(" ")
    assert_includes joined, "ship the gateway redesign"
    assert_includes joined, "Finish Slides"
    assert_nil segs.first[:speaker_name]
    assert_equal at, segs.first[:started_at]
  end
end
