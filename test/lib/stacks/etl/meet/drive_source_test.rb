require 'test_helper'

class Stacks::Etl::Meet::DriveSourceTest < ActiveSupport::TestCase
  setup do
    # Keep tests offline: no real Calendar enrichment call.
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: nil, attendees: [])
  end

  test 'normalizes a Drive transcript doc, cleaning the title from the doc name' do
    file = OpenStruct.new(id: 'doc1', name: 'Gateway sync - Transcript', created_time: '2026-01-01T09:00:00Z')
    svc = mock('drive')
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns("Drew: we should ship\nHugh: agreed, friday")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)
    # No attendees from Calendar -> fall back to name-only speakers; title from doc name.
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: 'Gateway sync', attendees: [])

    yielded = []
    Stacks::Etl::Meet::DriveSource.new('hugh@sanctuary.computer', since: Time.utc(2025, 1, 1)).each_meeting { |n| yielded << n }

    n = yielded.first
    assert_equal 'doc1', n[:external_id]
    assert_equal 'Gateway sync', n[:title]
    assert_equal 2, n[:segments].size
    assert_equal 'Drew', n[:segments].first[:speaker_name]
    assert_equal 'we should ship', n[:segments].first[:text]
    meeting = n[:build_source_record].call(Document.create!(source: :meet, external_id: 'doc1'))
    assert_equal 'doc1', meeting.drive_transcript_doc_id
    assert_equal 'Gateway sync', meeting.title
  end

  test 'cleans a title with a trailing timestamp parenthetical' do
    src = Stacks::Etl::Meet::DriveSource.allocate
    assert_equal 'Kyle, Sam & Hugh', src.send(:clean_title, 'Kyle, Sam & Hugh (2026/06/27 17:00 GMT-7) - Transcript')
  end

  test 'does not misparse URL / timestamp / non-name lines as speakers' do
    src = Stacks::Etl::Meet::DriveSource.allocate
    segs = src.send(:parse_segments, "Drew Smith: we should ship\nhttps://meet.google.com/abc was shared\n10:30 short break\nHugh: agreed")
    assert_equal ['Drew Smith', 'Hugh'], segs.map { |s| s[:speaker_name] }
  end

  test 'keeps speakers with initials or parenthetical labels (does not drop their text)' do
    src = Stacks::Etl::Meet::DriveSource.allocate
    segs = src.send(:parse_segments, "J.R.: kicking off\nJohn Doe (Guest): joining late\nHugh: welcome")
    assert_equal ['J.R.', 'John Doe (Guest)', 'Hugh'], segs.map { |s| s[:speaker_name] }
    assert_equal ['kicking off', 'joining late', 'welcome'], segs.map { |s| s[:text] }
  end

  test 'a spoken sentence containing a colon is NOT a new speaker (privacy: keeps 1:1 count honest)' do
    src = Stacks::Etl::Meet::DriveSource.allocate
    segs = src.send(:parse_segments, "Alice: I think the answer is: yes\nBob: agreed")
    # Only two real speakers — the mid-sentence "is:" must not spawn a phantom 3rd speaker.
    assert_equal ['Alice', 'Bob'], segs.map { |s| s[:speaker_name] }
    assert_equal 'I think the answer is: yes', segs.first[:text]
  end

  test 'recognizes Meet anonymous "Speaker N" labels as speakers' do
    src = Stacks::Etl::Meet::DriveSource.allocate
    segs = src.send(:parse_segments, "Speaker 1: hello\nSpeaker 2: hi there\nAlice: welcome")
    assert_equal ['Speaker 1', 'Speaker 2', 'Alice'], segs.map { |s| s[:speaker_name] }
  end

  test 'body lines like "Action 1:" are NOT phantom speakers (keeps 1:1 count honest)' do
    src = Stacks::Etl::Meet::DriveSource.allocate
    # A real 1:1 (Alice + Bob) whose body contains "Action 1:" / "Phase 2:" must stay a
    # 2-speaker meeting — a phantom 3rd speaker would lift it out of the 1:1 exclusion.
    segs = src.send(:parse_segments, "Alice: lets plan\nAction 1: ship it\nPhase 2: review\nBob: sounds good")
    assert_equal ['Alice', 'Bob'], segs.map { |s| s[:speaker_name] }
  end

  test 'drops system/footer lines instead of misattributing them to a speaker' do
    src = Stacks::Etl::Meet::DriveSource.allocate
    segs = src.send(:parse_segments, "Alice: kicking off the sync\nRecording stopped\nBob left the call\nBob: see you")
    # Footer/system lines are dropped, NOT glued onto Alice's (or Bob's) turn.
    assert_equal ['Alice', 'Bob'], segs.map { |s| s[:speaker_name] }
    assert_equal 'kicking off the sync', segs.first[:text]
    assert_equal 'see you', segs.last[:text]
  end

  test 'clean_title preserves legitimate parentheticals, strips only the Meet date stamp' do
    src = Stacks::Etl::Meet::DriveSource.allocate
    assert_equal 'Planning (3 items)', src.send(:clean_title, 'Planning (3 items) - Transcript')
    assert_equal 'Roadmap (Q3 2026)', src.send(:clean_title, 'Roadmap (Q3 2026) - Transcript')
    assert_equal 'Goals (2026 Goals)', src.send(:clean_title, 'Goals (2026 Goals) - Transcript')
    assert_equal 'Retro (5:00 format)', src.send(:clean_title, 'Retro (5:00 format) - Transcript') # bare clock time kept
    assert_equal 'Standup', src.send(:clean_title, 'Standup (2026/06/27 17:00 GMT-7) - Transcript')
  end

  test 'skips a Drive doc the Meet API sync already ingested (reverse dedup)' do
    # The API sync created a Document keyed on the conference record, recording the Drive
    # doc id in raw_metadata. The Drive backfill must defer to it, not double-ingest.
    Document.create!(source: :meet, external_id: 'conferenceRecords/7', raw_metadata: { 'drive_doc_id' => 'docDUP' })
    file = OpenStruct.new(id: 'docDUP', name: 'Sync - Transcript', created_time: '2026-01-01T09:00:00Z')
    svc = mock('drive')
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    yielded = []
    Stacks::Etl::Meet::DriveSource.new('hugh@sanctuary.computer', since: Time.utc(2025, 1, 1)).each_meeting { |n| yielded << n }
    assert_empty yielded # deferred to the existing API Document; no export_file call, no dup
  end

  test 're-scan does NOT skip the Drive doc the Drive sync itself created (re-ingests changes)' do
    # The Drive sync keys its own Document on external_id == file.id (and also stores it in
    # raw_metadata). The reverse-dedup must exclude THIS doc, or a corrected/re-included
    # transcript would never be re-yielded and its chunks would go stale.
    Document.create!(source: :meet, external_id: 'docSELF', raw_metadata: { 'drive_doc_id' => 'docSELF' })
    file = OpenStruct.new(id: 'docSELF', name: 'Sync - Transcript', created_time: '2026-01-01T09:00:00Z')
    svc = mock('drive')
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns("Alice: still here")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: 'Sync', attendees: [])

    yielded = []
    Stacks::Etl::Meet::DriveSource.new('hugh@sanctuary.computer', since: Time.utc(2025, 1, 1)).each_meeting { |n| yielded << n }
    assert_equal ['docSELF'], yielded.map { |n| n[:external_id] } # re-yielded, not skipped
  end

  test 'until_time bounds the Drive query to an older window (partitioned dedup)' do
    captured = nil
    svc = mock('drive')
    svc.stubs(:list_files).with { |kw| captured = kw[:q]; true }.returns(OpenStruct.new(files: [], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)
    Stacks::Etl::Meet::DriveSource.new('h@x.co', since: Time.utc(2026, 1, 1), until_time: Time.utc(2026, 3, 1)).each_meeting { |_| }
    assert_includes captured, "createdTime > '2026-01-01"
    assert_includes captured, "createdTime < '2026-03-01"
  end

  test 'accepts a string since and does not raise' do
    file = OpenStruct.new(id: 'doc2', name: 'Sync - Transcript', created_time: '2026-01-01T09:00:00Z')
    svc = mock('drive')
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns("Alice: hello")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    yielded = []
    assert_nothing_raised do
      Stacks::Etl::Meet::DriveSource.new('hugh@sanctuary.computer', since: '2025-01-01T00:00:00Z').each_meeting { |n| yielded << n }
    end
    assert_equal 1, yielded.size
  end
end
