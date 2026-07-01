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

  test "joins a notes doc to the existing transcript's meeting and inherits its exclusion" do
    meeting = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/1")
    Document.create!(source: :meet, external_id: "TRANSCRIPT_ID_123", source_record: meeting,
                     excluded: :auto_excluded, excluded_reason: :one_on_one)
    file = OpenStruct.new(id: "notesfile1", name: "Sync Title - 2026/06/30 15:00 EDT - Notes by Gemini",
                          created_time: "2026-06-30T15:00:00Z")
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns(SAMPLE) # from Task 3, contains TRANSCRIPT_ID_123
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    n = nil
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |x| n = x }
    assert_equal :gemini_notes, n[:source]
    assert_equal "notesfile1", n[:external_id]
    assert_equal "Sync Title", n[:title]
    assert_equal [:auto_excluded, :one_on_one], n[:inherit_exclusion]
    assert_equal ["ayaka@index-space.org", "hugh@sanctuary.computer"], n[:contacts].map { |c| c[:email] }
    doc = Document.create!(source: :gemini_notes, external_id: "notesfile1")
    built = n[:build_source_record].call(doc)
    assert_equal meeting.id, built.id # linked to the SAME meeting
  end

  test "joining an ELIGIBLE transcript inherits not_excluded verbatim (notes stay searchable)" do
    # Guards the progressive-enhancement path: a group meeting's transcript is eligible, so
    # its notes must inherit [:not_excluded, :none] and be chunked — NOT dropped. A future
    # nil-guard on the inherit values must never break this branch.
    meeting = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/2")
    Document.create!(source: :meet, external_id: "TRANSCRIPT_ID_123", source_record: meeting,
                     excluded: :not_excluded, excluded_reason: :none)
    file = OpenStruct.new(id: "notesfile3", name: "Sync Title - 2026/06/30 15:00 EDT - Notes by Gemini",
                          created_time: "2026-06-30T15:00:00Z")
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns(SAMPLE)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    n = nil
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |x| n = x }
    assert_equal [:not_excluded, :none], n[:inherit_exclusion]
    assert_nil n[:participant_count] # joined -> inherits, does not re-classify on invited count
  end

  test "a notes doc with no known transcript is standalone with its own classification" do
    file = OpenStruct.new(id: "notesfile2", name: "Team Weekly - 2026/06/30 15:00 EDT - Notes by Gemini",
                          created_time: "2026-06-30T15:00:00Z")
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns("Notes\n\n## Team Weekly\n\nInvited [A](mailto:a@x.co) [B](mailto:b@x.co) [C](mailto:c@x.co)\n\n### Summary\nStuff happened.")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)
    n = nil
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |x| n = x }
    assert_nil n[:inherit_exclusion]
    assert_equal 3, n[:participant_count] # invited count -> classifier sees a group
    doc = Document.create!(source: :gemini_notes, external_id: "notesfile2")
    built = n[:build_source_record].call(doc)
    assert_equal "notesfile2", built.gemini_notes_doc_id
    assert built.gemini_notes?
  end
end
