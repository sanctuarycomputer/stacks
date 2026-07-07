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
    segs = src.send(:notes_segments, SAMPLE, occurred_at: at)
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
    assert_equal "TRANSCRIPT_ID_123", n[:transcript_doc_id]   # inheritance resolved at ingest via for_drive_doc
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
    assert_equal "TRANSCRIPT_ID_123", n[:transcript_doc_id]
  end

  test "joins to API-ingested transcript keyed by conference-record id (regression: for_drive_doc vs find_by)" do
    # Regression guard: MeetApiSource keys the transcript Document on the conference-record id
    # (external_id: "conferenceRecords/9") and stores the Drive doc id only in raw_metadata.
    # The old find_by(external_id: transcript_drive_id) missed these rows entirely, causing the
    # notes to fall to the standalone branch and be reclassified by Invited count — which can
    # surface a private 1:1 with >2 invited (a no-show) into the corpus. for_drive_doc matches both.
    meeting = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "conferenceRecords/9")
    Document.create!(
      source: :meet,
      external_id: "conferenceRecords/9",
      source_record: meeting,
      excluded: :auto_excluded,
      excluded_reason: :one_on_one,
      raw_metadata: { "drive_doc_id" => "REAL_TRANSCRIPT_DRIVE_ID" }
    )

    # Notes text: Transcript link points to the Drive id (NOT the conference-record id),
    # 3 invited emails + benign title so the standalone classifier would (wrongly) allow it.
    api_notes_text = <<~TXT
      Notes

      ## Team Retrospective

      Invited [Alice](mailto:alice@sanctuary.computer) [Bob](mailto:bob@sanctuary.computer) [Carol](mailto:carol@sanctuary.computer)

      Meeting records [Transcript](https://docs.google.com/document/d/REAL_TRANSCRIPT_DRIVE_ID/edit?usp=drive_web)

      ### Summary
      We reviewed the sprint and planned the next one.
    TXT

    file = OpenStruct.new(id: "notesfile_api_regression", name: "Team Retrospective - 2026/06/30 15:00 EDT - Notes by Gemini",
                          created_time: "2026-06-30T15:00:00Z")
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns(api_notes_text)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    n = nil
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |x| n = x }
    # With the fix: join succeeds via raw_metadata->>'drive_doc_id', exclusion is inherited verbatim.
    # With the bug: join fails, falls to standalone, participant_count=3 → classifier marks not_excluded.
    assert_equal "REAL_TRANSCRIPT_DRIVE_ID", n[:transcript_doc_id],
                 "Notes carry the parsed transcript id; the connector inherits from the API-ingested transcript at ingest"
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
    assert_nil n[:transcript_doc_id]
    assert_equal 3, n[:participant_count]  # invited count -> classifier sees a group
    doc = Document.create!(source: :gemini_notes, external_id: "notesfile2")
    built = n[:build_source_record].call(doc)
    assert_equal "notesfile2", built.gemini_notes_doc_id
    assert built.gemini_notes?
  end

  test "exports the notes doc as text/markdown so hyperlinks (mailto + transcript) survive" do
    # Regression (prod): Google's text/plain export STRIPS links, flattening
    # "[Name](mailto:email)" and "[Transcript](url)" to bare text — so invited emails and the
    # transcript-doc-id both come back empty, every note falls to standalone and gets
    # auto-excluded on a 0 count. Only text/markdown preserves the link syntax the parsers need.
    # This mocha .with pins the export MIME: a revert to "text/plain" fails here.
    meeting = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/md")
    Document.create!(source: :meet, external_id: "TRANSCRIPT_ID_123", source_record: meeting,
                     excluded: :not_excluded, excluded_reason: :none)
    file = OpenStruct.new(id: "notesfile_md", name: "Sync Title - 2026/06/30 15:00 EDT - Notes by Gemini",
                          created_time: "2026-06-30T15:00:00Z")
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.expects(:export_file).with("notesfile_md", "text/markdown").returns(SAMPLE)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    n = nil
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |x| n = x }
    # Links survived the export -> transcript joins (inherits) and invited emails are attributed.
    assert_equal "TRANSCRIPT_ID_123", n[:transcript_doc_id]
    assert_equal ["ayaka@index-space.org", "hugh@sanctuary.computer"], n[:contacts].map { |c| c[:email] }
  end

  COMBINED = <<~TXT
    # **📝 Notes**

    ## **Business Meeting**

    Invited [Alice](mailto:alice@x.co) [Bob](mailto:bob@x.co) [Carol](mailto:carol@x.co)

    Meeting records [Transcript](https://docs.google.com/document/d/SELF_ID/edit?usp=drive_web&tab=t.wqjj)

    ### Summary
    We planned the sprint.

    # **📖 Transcript**

    ## **Business Meeting \\- Transcript**

    Alice: kicking off the sprint
    Bob: sounds good to me
    Carol: agreed
  TXT

  def combined_file = OpenStruct.new(id: "SELF_ID", name: "Business Meeting - 2026/06/30 15:00 EDT - Notes by Gemini",
                                   created_time: "2026-06-30T15:00:00Z")

  def stub_drive_returning(text, file: combined_file)
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns(text)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)
    svc
  end

  test "a combined doc yields a meet transcript record then a gemini_notes record, both for the same file" do
    stub_drive_returning(COMBINED)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }

    assert_equal [:meet, :gemini_notes], out.map { |r| r[:source] }
    tx, notes = out
    assert_equal "SELF_ID", tx[:external_id]
    assert_equal ["Alice", "Bob", "Carol"], tx[:segments].map { |s| s[:speaker_name] }
    assert_equal 3, tx[:participant_count]                 # actual speakers, not invited
    assert_equal "SELF_ID", tx[:raw_metadata]["drive_doc_id"]
    assert_equal "SELF_ID", notes[:transcript_doc_id]      # self-link -> inherits tx at ingest
    refute notes[:segments].any? { |s| s[:text].include?("kicking off the sprint") } # transcript not in notes
  end

  test "a combined doc whose transcript section has no speaker lines yields notes-only" do
    empty_tx = "# **📝 Notes**\n\n## **Quick Sync**\n\nInvited [A](mailto:a@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/SELF_ID/edit)\n\n### Summary\nShort.\n\n# **📖 Transcript**\n\n### Transcription ended after 00:01:30\n"
    stub_drive_returning(empty_tx)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }
    assert_equal [:gemini_notes], out.map { |r| r[:source] }   # no meet transcript emitted
    assert_equal 1, out.first[:participant_count]              # standalone -> invited count
  end

  test "the split transcript defers to an already-ingested transcript Document (reverse dedup)" do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/dup")
    Document.create!(source: :meet, external_id: "conferenceRecords/dup", source_record: m,
                     excluded: :not_excluded, excluded_reason: :none, raw_metadata: { "drive_doc_id" => "SELF_ID" })
    stub_drive_returning(COMBINED)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }
    assert_equal [:gemini_notes], out.map { |r| r[:source] } # transcript deferred; only notes yielded
    assert_equal "SELF_ID", out.first[:transcript_doc_id]     # notes still inherit from the API doc at ingest
  end

  test "detects the combined format when the transcript link points to the doc's own id" do
    assert src.send(:combined_format?, COMBINED, "SELF_ID")
    refute src.send(:combined_format?, COMBINED, "OTHER_ID")  # external transcript -> old format
    refute src.send(:combined_format?, "no transcript link here", "SELF_ID")
  end

  test "splits combined markdown into notes-body and transcript at the transcript heading" do
    notes_md, transcript_md = src.send(:split_transcript, COMBINED)
    assert_includes notes_md, "We planned the sprint"
    refute_includes notes_md, "kicking off the sprint"      # transcript dialogue not in notes
    assert_includes transcript_md, "Alice: kicking off the sprint"
    assert_includes transcript_md, "Carol: agreed"
  end

  test "split returns empty transcript when there is no transcript heading" do
    notes_md, transcript_md = src.send(:split_transcript, "# Notes\n\n### Summary\nJust notes.")
    assert_includes notes_md, "Just notes."
    assert_equal "", transcript_md
  end

  test "combined transcript head-count uses ACTUAL speakers, not the invited count (privacy)" do
    # 3 invited, but only 2 people actually speak -> a 1:1 by real attendance despite 3 invites.
    md = "# 📝 Notes\n\n## Kyle & Hugh\n\nInvited [K](mailto:k@x.co) [H](mailto:h@x.co) [X](mailto:x@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/SELF_ID/edit)\n\n### Summary\nSensitive.\n\n# 📖 Transcript\n\nKyle: hey\nHugh: hi\n"
    stub_drive_returning(md)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }
    tx = out.find { |r| r[:source] == :meet }
    assert_equal 2, tx[:participant_count], "head-count must be distinct speakers (2), not invited (3)"
  end

  test "combined transcript with BOLD markdown speaker turns parses speakers (real Gemini format)" do
    # Real Gemini transcripts render each turn as "**Name:** text" (bold), with "### **00:01:15**"
    # timestamp headings between turns. The plain-text speaker parser matches ZERO of these unless
    # the ** emphasis is stripped first. Without the fix, tx would be nil (notes-only).
    md = <<~MD
      # **📝 Notes**

      ## **Business Meeting**

      Invited [A](mailto:a@x.co) [B](mailto:b@x.co) [C](mailto:c@x.co)

      Meeting records [Transcript](https://docs.google.com/document/d/SELF_ID/edit?usp=drive_web&tab=t.abc)

      ### Summary
      Stuff happened.

      # **📖 Transcript**

      ### **00:01:15** {#00:01:15}

      **Evie Kling:** Hi, Christian.

      **Christian Perez:** Hey, how are you?

      **Andy Brewer:** Let's begin the sync.
    MD
    stub_drive_returning(md)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }
    tx = out.find { |r| r[:source] == :meet }
    assert tx, "a transcript record must be emitted — bold speaker turns must parse (not degrade to notes-only)"
    assert_equal ["Evie Kling", "Christian Perez", "Andy Brewer"], tx[:segments].map { |s| s[:speaker_name] }
    assert_equal 3, tx[:participant_count]
    assert_includes tx[:segments].first[:text], "Hi, Christian." # ** stripped from the utterance too
  end
end
