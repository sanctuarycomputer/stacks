require 'test_helper'

class StacksMeetingsSweepTest < ActiveSupport::TestCase
  Sweep = Stacks::Meetings::Sweep

  def setup
    Stacks::AI.stubs(:configured?).returns(true)
    @tracker = tracker!("Harvey Staff Augmentation")
  end

  def meeting!(title: "Harvey weekly sync", started_at: 2.days.ago)
    Meeting.create!(title: title, started_at: started_at, meet_source: :meet_api)
  end

  def doc!(meeting, source: :meet, title: meeting.title, content_hash: SecureRandom.hex(8),
           chunks: ["We reviewed the Harvey staging build."], speaker: "Sam Lead", occurred_at: meeting.started_at)
    d = Document.create!(source: source, external_id: SecureRandom.hex(6), title: title,
                         occurred_at: occurred_at, content_hash: content_hash, source_record: meeting)
    chunks.each_with_index { |c, i| d.chunks.create!(position: i, content: c, speaker_name: speaker, source: source, occurred_at: occurred_at) }
    d
  end

  def exclude!(doc)
    doc.update_columns(excluded: Document.excludeds[:manually_excluded])
  end

  def tracker!(name, **attrs)
    ProjectTracker.new(name: name, **attrs).tap { |t| t.save!(validate: false) }
  end

  def answer(tracker_ids: [@tracker.id], confidence: 0.9, rationale: "Title names the client.")
    Stacks::AI::Result.new({ "tracker_ids" => tracker_ids, "confidence" => confidence, "rationale" => rationale }, 1000, 100)
  end

  # Runs the sweep once with one stubbed answer and returns the prompt it sent.
  def prompt_sent(result = answer)
    prompt = nil
    Stacks::AI.expects(:extract).once.with { |args| prompt = args[:prompt]; true }.returns(result)
    Sweep.run!
    prompt
  end

  def linked_ids(meeting)
    meeting.project_trackers.reset.pluck(:id).sort
  end

  def join_rows
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM meetings_project_trackers").to_i
  end

  test "a meeting with an eligible document is matched once" do
    m = meeting!
    doc!(m)
    Stacks::AI.expects(:extract).once.returns(answer)
    stats = Sweep.run!
    assert_equal [@tracker.id], linked_ids(m)
    scan = m.reload.meeting_scan
    assert scan.linked?
    assert_equal 0.9, scan.confidence
    assert_equal "Title names the client.", scan.rationale
    assert_not scan.human_locked?
    assert_equal m.eligible_content_hash, scan.scanned_hash
    assert_equal 1, stats[:scanned]
    assert_equal 1, stats[:linked]
    assert_equal 1000, stats[:input_tokens]
    assert_equal 100, stats[:output_tokens]
  end

  test "a second run makes no model call" do
    doc!(meeting!)
    Stacks::AI.stubs(:extract).returns(answer)
    Sweep.run!
    Stacks::AI.expects(:extract).never
    assert_equal 0, Sweep.run![:scanned]
  end

  test "there is no environment switch: the sweep runs whenever it is called" do
    assert_not Sweep.respond_to?(:enabled?)
    source = File.read(Rails.root.join("lib/stacks/meetings/sweep.rb"))
    assert_no_match(/\bENV\b/, source, "the sweep reads no environment variable")
    m = meeting!
    doc!(m)
    Stacks::AI.expects(:extract).once.returns(answer)
    stats = Sweep.run!
    assert_equal 1, stats[:linked]
    assert_not stats.key?(:skipped_disabled)
    assert m.reload.meeting_scan.linked?
  end

  test "confidence under the threshold is no_match, and the scan keeps the model's answer" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(confidence: 0.59, rationale: "Maybe Harvey."))
    stats = Sweep.run!
    assert_equal 0, join_rows
    scan = m.reload.meeting_scan
    assert scan.no_match?
    assert_equal 0.59, scan.confidence
    assert_equal "Maybe Harvey.", scan.rationale
    assert_equal 1, stats[:no_match]
  end

  test "confidence exactly at the threshold links" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(confidence: Sweep::CONFIDENCE_THRESHOLD))
    Sweep.run!
    assert_equal [@tracker.id], linked_ids(m)
    assert_equal 0.6, m.reload.meeting_scan.confidence
    assert m.meeting_scan.linked?
  end

  test "a confidence outside 0 to 1 is clamped before it is stored" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(confidence: 5))
    Sweep.run!
    assert_equal 1.0, m.reload.meeting_scan.confidence
  end

  test "a very long rationale is stored at 300 characters, on one line" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(rationale: "Names  the\nclient. " + ("x" * 50_000)))
    Sweep.run!
    rationale = m.reload.meeting_scan.rationale
    assert_equal 300, rationale.length
    assert rationale.start_with?("Names the client. xxx")
  end

  test "a rationale that is not a string does not raise and is stored as text" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(rationale: { "why" => "Title names the client." }))
    stats = Sweep.run!
    assert_equal 0, stats[:errored]
    assert_equal({ "why" => "Title names the client." }.to_s.squish, m.reload.meeting_scan.rationale)
    assert m.meeting_scan.linked?
  end

  test "a dry run reports the confidence and rationale as they would be stored" do
    doc!(meeting!)
    Stacks::AI.stubs(:extract).returns(answer(confidence: 5, rationale: "y" * 50_000))
    result = Sweep.run!(dry_run: true)[:results].first
    assert_equal 1.0, result[:confidence]
    assert_equal "y" * 300, result[:rationale]
    Stacks::AI.stubs(:extract).returns(answer(rationale: { "why" => "x" }))
    assert_kind_of String, Sweep.run!(dry_run: true)[:results].first[:rationale]
  end

  test "an empty answer is no_match" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: []))
    Sweep.run!
    assert_equal 0, join_rows
    assert m.reload.meeting_scan.no_match?
  end

  test "a tracker id the model invents is ignored" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: [@tracker.id, 987_654]))
    Sweep.run!
    assert_equal [@tracker.id], linked_ids(m)
  end

  test "an answer of only invented ids is no_match" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: [987_654]))
    Sweep.run!
    assert_equal 0, join_rows
    assert m.reload.meeting_scan.no_match?
  end

  test "a transcript and its notes cost one call and get one link and one scan" do
    m = meeting!
    doc!(m)
    doc!(m, source: :gemini_notes)
    Stacks::AI.expects(:extract).once.returns(answer)
    Sweep.run!
    assert_equal 1, join_rows
    assert_equal 1, MeetingScan.count
  end

  test "the prompt carries the eligible document's title, people and text, and nothing from an excluded sibling" do
    m = meeting!(title: "PRIVATE-TITLE from the excluded document")
    notes = doc!(m, source: :gemini_notes, title: "Harvey weekly sync", chunks: ["Notes: the staging build was approved."], speaker: nil)
    notes.document_contacts.create!(role: "attendee", name: "Ada Attendee", email: "ada@client.example")
    transcript = doc!(m, title: "PRIVATE-TITLE from the excluded document", chunks: ["SECRET-CHUNK salary talk"], speaker: "Hidden Speaker")
    transcript.document_contacts.create!(role: "attendee", name: "Hidden Contact", email: "hidden@client.example")
    exclude!(transcript)
    m.participants.create!(name: "Nima Client")
    m.segments.create!(position: 0, text: "SECRET-SEGMENT salary talk", speaker_name: "Segment Speaker")

    prompt = prompt_sent

    assert_includes prompt, "Meeting title: Harvey weekly sync"
    assert_includes prompt, "Nima Client"
    assert_includes prompt, "Ada Attendee <ada@client.example>"
    assert_includes prompt, "Notes: the staging build was approved."
    %w[PRIVATE-TITLE SECRET-CHUNK SECRET-SEGMENT Hidden\ Speaker Segment\ Speaker Hidden\ Contact hidden@client.example].each do |leak|
      assert_not_includes prompt, leak
    end
  end

  test "the prompt title comes from the eligible transcript when the notes are excluded" do
    m = meeting!(title: "PRIVATE NOTES TITLE")
    exclude!(doc!(m, source: :gemini_notes, title: "PRIVATE NOTES TITLE"))
    doc!(m, title: "Harvey weekly sync")
    prompt = prompt_sent
    assert_includes prompt, "Meeting title: Harvey weekly sync"
    assert_not_includes prompt, "PRIVATE NOTES TITLE"
  end

  test "an untitled eligible document never borrows the meeting row's title" do
    m = meeting!(title: "PRIVATE-TITLE from the excluded document")
    doc!(m, title: nil)
    exclude!(doc!(m, source: :gemini_notes, title: "PRIVATE-TITLE from the excluded document"))
    prompt = nil
    Stacks::AI.expects(:extract).once.with { |args| prompt = args[:prompt]; true }.returns(answer)
    stats = Sweep.run!(dry_run: true)
    assert_not_includes prompt, "PRIVATE-TITLE"
    assert_includes prompt, "Meeting title: (untitled)"
    assert_not_includes stats[:results].to_s, "PRIVATE-TITLE"
  end

  test "the prompt names the people who spoke in an eligible transcript" do
    m = meeting!
    doc!(m, speaker: "Sam Lead")
    assert_includes prompt_sent, "Sam Lead"
  end

  test "each document gets its own body budget, notes first" do
    m = meeting!
    doc!(m, chunks: ["t" * 3_000], speaker: nil)
    doc!(m, source: :gemini_notes, chunks: ["n" * 3_000], speaker: nil)
    prompt = prompt_sent
    assert_includes prompt, "n" * Sweep::BODY_CHARS
    assert_not_includes prompt, "n" * (Sweep::BODY_CHARS + 1)
    assert_includes prompt, "t" * Sweep::BODY_CHARS
    assert_not_includes prompt, "t" * (Sweep::BODY_CHARS + 1)
    assert_operator prompt.index("nnnn"), :<, prompt.index("tttt")
  end

  test "only the first five chunks of a document are read" do
    m = meeting!
    doc!(m, chunks: (1..6).map { |i| "chunk-number-#{i}" })
    prompt = prompt_sent
    assert_includes prompt, "chunk-number-5"
    assert_not_includes prompt, "chunk-number-6"
  end

  test "a meeting whose only documents are excluded is never sent and gets no scan" do
    m = meeting!
    exclude!(doc!(m))
    Stacks::AI.expects(:extract).never
    Sweep.run!
    assert_nil m.reload.meeting_scan
  end

  # The 90-day backfill window, as for weekly ships

  test "the backfill window is the weekly ship sweep's" do
    assert_equal 90.days, Sweep::BACKFILL_WINDOW
    assert_equal Stacks::WeeklyShips::Sweep::BACKFILL_WINDOW, Sweep::BACKFILL_WINDOW
    assert_equal Stacks::WeeklyShips::Sweep::CONFIDENCE_THRESHOLD, Sweep::CONFIDENCE_THRESHOLD
  end

  test "a meeting inside the 90 days is matched however long ago it was held" do
    m = meeting!(started_at: 89.days.ago)
    doc!(m)
    Stacks::AI.expects(:extract).once.returns(answer)
    Sweep.run!
    assert m.reload.meeting_scan.linked?
  end

  test "a meeting older than 90 days gets an out_of_scope scan and no model call" do
    m = meeting!(started_at: 91.days.ago)
    doc!(m)
    Stacks::AI.expects(:extract).never
    stats = Sweep.run!
    scan = m.reload.meeting_scan
    assert scan.out_of_scope?
    assert_not scan.human_locked?
    assert_equal m.eligible_content_hash, scan.scanned_hash
    assert_nil scan.confidence
    assert_nil scan.rationale
    assert_equal 0, join_rows
    assert_equal 1, stats[:out_of_scope]
    assert_equal 1, stats[:scanned]
    assert_equal 0, stats[:errored]
    # Recorded, so it is not looked at again.
    assert_equal 0, Sweep.run![:scanned]
  end

  test "an old linked meeting whose content changes stays linked, keeps its trackers and loses its reason" do
    m = meeting!(started_at: 91.days.ago)
    doc = doc!(m, content_hash: "v1")
    m.project_trackers << @tracker
    MeetingScan.create!(meeting: m, outcome: :linked, scanned_at: 80.days.ago, scanned_hash: m.eligible_content_hash,
                        confidence: 0.9, rationale: "Written from the old text.")
    doc.update!(content_hash: "v2")
    Stacks::AI.expects(:extract).never
    Sweep.run!
    scan = m.reload.meeting_scan
    assert scan.linked?, "it still has a project, so it stays under Linked"
    assert_equal m.eligible_content_hash, scan.scanned_hash
    assert_nil scan.rationale, "the reason was written from text the meeting no longer has"
    assert_nil scan.confidence
    assert_equal [@tracker.id], linked_ids(m)
  end

  test "a meeting with no start time is dated by its newest eligible document" do
    recent = Meeting.create!(title: "Harvey weekly sync", meet_source: :meet_api)
    doc!(recent, occurred_at: 3.days.ago)
    old = Meeting.create!(title: "Harvey kickoff", meet_source: :meet_api)
    doc!(old, occurred_at: 120.days.ago)
    Stacks::AI.expects(:extract).once.returns(answer)
    Sweep.run!
    assert recent.reload.meeting_scan.linked?
    assert old.reload.meeting_scan.out_of_scope?
  end

  test "a meeting with no date at all is recorded out of scope once, not an error every night" do
    m = Meeting.create!(title: "Harvey weekly sync", meet_source: :meet_api)
    doc!(m, occurred_at: nil)
    Stacks::AI.expects(:extract).never
    stats = Sweep.run!
    assert_equal 0, stats[:errored]
    assert_equal 1, stats[:out_of_scope]
    assert m.reload.meeting_scan.out_of_scope?
    assert_equal 0, Sweep.run![:scanned], "recorded, so it is not looked at again"
  end

  # Rescans: links are added, never removed

  test "a rescan after a content change never removes an existing tracker and adds a newly returned one" do
    m = meeting!
    doc = doc!(m, content_hash: "v1")
    other = tracker!("Acme Phase 2")
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: [@tracker.id]))
    Sweep.run!
    first_hash = m.reload.meeting_scan.scanned_hash

    doc.update!(content_hash: "v2")
    Stacks::AI.expects(:extract).once.returns(answer(tracker_ids: [other.id], confidence: 0.8, rationale: "Now about Acme."))
    Sweep.run!

    assert_equal [@tracker.id, other.id].sort, linked_ids(m)
    scan = m.reload.meeting_scan
    assert scan.linked?
    assert_not scan.human_locked?
    assert_not_equal first_hash, scan.scanned_hash
    assert_equal m.eligible_content_hash, scan.scanned_hash
    assert_equal 0.8, scan.confidence
    assert_equal "Now about Acme.", scan.rationale
  end

  test "a rescan that matches nothing keeps the trackers, and the scan stays linked with the new answer" do
    m = meeting!
    doc = doc!(m, content_hash: "v1")
    Stacks::AI.stubs(:extract).returns(answer)
    Sweep.run!
    doc.update!(content_hash: "v2")
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: [], confidence: 0.2, rationale: "Reads as internal now."))
    stats = Sweep.run!
    assert_equal [@tracker.id], linked_ids(m)
    scan = m.reload.meeting_scan
    assert scan.linked?
    assert_equal 0.2, scan.confidence
    assert_equal "Reads as internal now.", scan.rationale
    assert_equal 1, stats[:linked]
  end

  test "a link to a tracker completed since survives a rescan" do
    m = meeting!
    doc = doc!(m, content_hash: "v1")
    Stacks::AI.stubs(:extract).returns(answer)
    Sweep.run!

    @tracker.update_columns(work_completed_at: 1.day.ago)
    doc.update!(content_hash: "v2")
    Stacks::AI.expects(:extract).once.returns(answer(tracker_ids: []))
    stats = Sweep.run!

    assert_equal [@tracker.id], linked_ids(m)
    scan = m.reload.meeting_scan
    assert scan.linked?
    assert_equal m.eligible_content_hash, scan.scanned_hash
    assert_equal 1, stats[:linked]
  end

  test "a link that was there before any scan is kept, and the sweep does not lock" do
    m = meeting!
    doc!(m)
    other = tracker!("Acme Phase 2")
    m.project_trackers << @tracker
    assert_nil m.reload.meeting_scan

    Stacks::AI.expects(:extract).once.returns(answer(tracker_ids: [other.id]))
    Sweep.run!

    assert_equal [@tracker.id, other.id].sort, linked_ids(m)
    assert_not m.reload.meeting_scan.human_locked?
  end

  test "a tracker the meeting already has is not linked twice" do
    m = meeting!
    doc!(m)
    m.project_trackers << @tracker
    Stacks::AI.stubs(:extract).returns(answer)
    stats = Sweep.run!
    assert_equal 0, stats[:errored]
    assert_equal 1, join_rows
  end

  test "the scan's hash is taken from the documents the prompt was built from, not read again" do
    m = meeting!
    transcript = doc!(m, content_hash: "v1")
    notes = doc!(m, source: :gemini_notes, content_hash: "n1")
    expected = Meeting.content_hash_for([transcript, notes])
    # A second read could see a document that changed after the prompt's were loaded.
    Meeting.any_instance.expects(:eligible_content_hash).never
    Stacks::AI.expects(:extract).once.returns(answer)
    Sweep.run!
    assert_equal expected, MeetingScan.find_by!(meeting_id: m.id).scanned_hash
  end

  # The one case where the sweep removes links

  test "a matched meeting that stops being readable loses its links and scan, with no model call" do
    m = meeting!
    doc = doc!(m)
    Stacks::AI.stubs(:extract).returns(answer)
    Sweep.run!
    exclude!(doc)
    Stacks::AI.expects(:extract).never
    stats = Sweep.run!
    assert_equal 1, stats[:removed]
    assert_equal 0, join_rows
    assert_equal 0, MeetingScan.count
  end

  test "an unreadable meeting outside the window is cleaned up too" do
    m = meeting!(started_at: 140.days.ago)
    doc = doc!(m)
    m.project_trackers << @tracker
    MeetingScan.create!(meeting: m, outcome: :linked, scanned_at: 130.days.ago, scanned_hash: m.eligible_content_hash)
    exclude!(doc)
    assert_equal 1, Sweep.run![:removed]
    assert_equal 0, join_rows
    assert_equal 0, MeetingScan.count
  end

  test "a human-locked scan is never rematched, and what a person linked stays when the meeting stops being readable" do
    m = meeting!
    doc = doc!(m, content_hash: "v1")
    m.link_project!(@tracker)
    doc.update!(content_hash: "v2")
    Stacks::AI.expects(:extract).never
    Sweep.run!
    assert_equal [@tracker.id], linked_ids(m)

    exclude!(doc)
    assert_equal 0, Sweep.run![:removed]
    assert_equal [@tracker.id], linked_ids(m)
    assert m.reload.meeting_scan.human_locked?
  end

  test "a human-locked old meeting is not rewritten as out_of_scope" do
    m = meeting!(started_at: 120.days.ago)
    doc = doc!(m, content_hash: "v1")
    m.link_project!(@tracker)
    doc.update!(content_hash: "v2")
    assert_equal 0, Sweep.run![:scanned]
    assert m.reload.meeting_scan.linked?
  end

  test "a person locking the meeting while the model is answering wins" do
    m = meeting!
    doc!(m)
    Stacks::AI.expects(:extract).once.with { |_|
      MeetingScan.create!(meeting: m, outcome: :no_match, human_locked: true, scanned_at: Time.zone.now, scanned_hash: "person")
      true
    }.returns(answer)
    Sweep.run!
    assert_equal 0, join_rows
    scan = m.reload.meeting_scan
    assert scan.no_match?
    assert_equal "person", scan.scanned_hash
    assert_nil scan.rationale
  end

  test "a no_match meeting is not retried just because a tracker was created" do
    m = meeting!
    doc!(m)
    MeetingScan.create!(meeting: m, outcome: :no_match, scanned_at: 1.day.ago, scanned_hash: m.eligible_content_hash)
    tracker!("Brand New Client Project")
    Stacks::AI.expects(:extract).never
    assert_equal 0, Sweep.run![:scanned]
    assert m.reload.meeting_scan.no_match?
  end

  test "a tracker for one of our own companies is not a candidate" do
    # Every open tracker reads as internal here; unstubbed, a tracker with no
    # Forecast projects is client work, which is what every other test relies on.
    ProjectTracker.any_instance.stubs(:internal_client?).returns(true)
    meeting = meeting!
    doc!(meeting)
    Stacks::AI.expects(:extract).with { |args| @prompt = args[:prompt]; true }.returns(answer)
    Sweep.run!
    assert_not_includes @prompt, "id #{@tracker.id}:"
    assert_equal 0, join_rows, "an internal tracker's id is not accepted either"
    assert_equal "no_match", meeting.reload.meeting_scan.outcome
  end

  test "a completed tracker is not a candidate" do
    done = tracker!("Finished Project", work_completed_at: 1.month.ago)
    doc!(meeting!)
    prompt = prompt_sent(answer(tracker_ids: [done.id]))
    assert_includes prompt, "- id #{@tracker.id}: Harvey Staff Augmentation"
    assert_not_includes prompt, "id #{done.id}:"
    assert_not_includes prompt, "Finished Project"
    assert_equal 0, join_rows, "a completed tracker's id is not accepted either"
  end

  test "the prompt lists each candidate tracker with its people" do
    ProjectTracker.any_instance.stubs(:matcher_people).returns(["Sam Lead <sam@sanctuary.computer>"])
    doc!(meeting!, speaker: nil)
    line = prompt_sent.lines.find { |l| l.include?("- id #{@tracker.id}:") }
    assert_includes line, "Harvey Staff Augmentation"
    assert_includes line, "Sam Lead <sam@sanctuary.computer>"
  end

  test "the system prompt keeps its rule about interviews and prospects" do
    assert_includes Sweep::SYSTEM_PROMPT.squish, "An interview or conversation with a job candidate"
    assert_includes Sweep::SYSTEM_PROMPT.squish, "never matches a project"
  end

  test "an AI error on one meeting is counted, leaves no scan, and the run goes on" do
    newer = meeting!(started_at: 1.day.ago)
    older = meeting!(started_at: 3.days.ago)
    doc!(newer)
    doc!(older)
    Stacks::AI.stubs(:extract).raises(Stacks::AI::Error, "boom").then.returns(answer)
    stats = Sweep.run!
    assert_equal 1, stats[:errored]
    assert_equal 2, stats[:scanned]
    assert_nil newer.reload.meeting_scan
    assert older.reload.meeting_scan.linked?
  end

  test "a network error the provider does not wrap is handled the same way" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).raises(Net::ReadTimeout)
    stats = nil
    assert_nothing_raised { stats = Sweep.run! }
    assert_equal 1, stats[:errored]
    assert_nil m.reload.meeting_scan
  end

  test "a dry run calls the model and saves nothing" do
    m = meeting!
    doc!(m)
    Stacks::AI.expects(:extract).once.returns(answer)
    stats = Sweep.run!(dry_run: true)
    assert_equal 0, join_rows
    assert_equal 0, MeetingScan.count
    assert_equal [{ meeting_id: m.id, title: "Harvey weekly sync", tracker_ids: [@tracker.id],
                    confidence: 0.9, rationale: "Title names the client." }], stats[:results]
    assert_equal 1, stats[:scanned]
  end

  test "a dry run reports no tracker ids for an answer that would not be saved" do
    doc!(meeting!)
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: [@tracker.id, 987_654], confidence: 0.4))
    assert_equal [], Sweep.run!(dry_run: true)[:results].first[:tracker_ids]
  end

  test "a dry run does not clean up unreadable meetings" do
    m = meeting!
    doc = doc!(m)
    Stacks::AI.stubs(:extract).returns(answer)
    Sweep.run!
    exclude!(doc)
    Sweep.run!(dry_run: true)
    assert_equal 1, join_rows
    assert_equal 1, MeetingScan.count
  end

  test "a dry run previews only meetings the model would be asked about, and records nothing for old ones" do
    old = meeting!(started_at: 100.days.ago)
    doc!(old)
    recent = meeting!(started_at: 5.days.ago)
    doc!(recent)
    Stacks::AI.expects(:extract).once.returns(answer)
    stats = Sweep.run!(dry_run: true, limit: 1)
    assert_equal [recent.id], stats[:results].map { |r| r[:meeting_id] }
    assert_equal 0, MeetingScan.count
  end

  test "a dry run's limit caps the model calls, newest meetings first" do
    oldest = meeting!(started_at: 5.days.ago)
    newest = meeting!(started_at: 1.day.ago)
    middle = meeting!(started_at: 3.days.ago)
    [oldest, newest, middle].each { |m| doc!(m) }
    Stacks::AI.expects(:extract).twice.returns(answer)
    stats = Sweep.run!(dry_run: true, limit: 2)
    assert_equal [newest.id, middle.id], stats[:results].map { |r| r[:meeting_id] }
  end

  test "a normal run has no cap and takes no limit" do
    assert_not Sweep.const_defined?(:MAX_PER_RUN)
    assert_raises(ArgumentError) { Sweep.run!(limit: 1) }
    # One more than the cap the first version had.
    61.times { |i| doc!(meeting!(started_at: (i + 1).hours.ago), chunks: []) }
    Stacks::AI.expects(:extract).times(61).returns(answer)
    stats = Sweep.run!
    assert_equal 61, stats[:scanned]
    assert_equal 61, MeetingScan.linked.count
  end

  test "without an AI key nothing is called and nothing is written" do
    Stacks::AI.stubs(:configured?).returns(false)
    doc!(meeting!)
    doc!(meeting!)
    Stacks::AI.expects(:extract).never
    stats = Sweep.run!
    assert_equal 2, stats[:skipped_no_key]
    assert_equal 0, stats[:errored]
    assert_equal 0, MeetingScan.count
  end

  # ProjectTracker#matcher_people

  def forecast_person!(first, last, email)
    ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), first_name: first, last_name: last, email: email)
  end

  test "matcher_people returns current leads and the recent team as name and email" do
    fclient = ForecastClient.create!(forecast_id: 81_001, name: "Harvey")
    fproject = ForecastProject.create!(forecast_id: 81_100, name: "Harvey Build", code: "HRV-1", forecast_client: fclient)
    ProjectTrackerForecastProject.create!(project_tracker: @tracker, forecast_project: fproject)
    @tracker.reload

    lead = AdminUser.create!(email: "lead@sanctuary.computer", password: "password123", password_confirmation: "password123")
    forecast_person!("Sam", "Lead", "lead@sanctuary.computer")
    ProjectLeadPeriod.new(project_tracker: @tracker, admin_user: lead, started_at: Date.today.beginning_of_month).save!(validate: false)

    recent = forecast_person!("Rae", "Recent", "rae@sanctuary.computer")
    nameless = forecast_person!(nil, " ", "nameless@sanctuary.computer")
    stale = forecast_person!("Stu", "Stale", "stu@sanctuary.computer")
    elsewhere = forecast_person!("Elle", "Elsewhere", "elle@sanctuary.computer")
    other_project = ForecastProject.create!(forecast_id: 81_101, name: "Other", code: "OTH-1", forecast_client: fclient)
    ForecastAssignment.create!(forecast_id: 1, forecast_person: recent, forecast_project: fproject, start_date: Date.today - 20, end_date: Date.today - 10, allocation: 28_800)
    ForecastAssignment.create!(forecast_id: 2, forecast_person: recent, forecast_project: fproject, start_date: Date.today - 9, end_date: Date.today - 1, allocation: 28_800)
    ForecastAssignment.create!(forecast_id: 3, forecast_person: nameless, forecast_project: fproject, start_date: Date.today - 5, end_date: Date.today + 5, allocation: 28_800)
    ForecastAssignment.create!(forecast_id: 4, forecast_person: stale, forecast_project: fproject, start_date: Date.today - 120, end_date: Date.today - 61, allocation: 28_800)
    ForecastAssignment.create!(forecast_id: 5, forecast_person: elsewhere, forecast_project: other_project, start_date: Date.today - 5, end_date: Date.today, allocation: 28_800)

    assert_equal ["<nameless@sanctuary.computer>", "Rae Recent <rae@sanctuary.computer>", "Sam Lead <lead@sanctuary.computer>"],
                 ProjectTracker.find(@tracker.id).matcher_people.sort
  end

  test "matcher_people is empty, not an error, for a tracker with no Forecast projects or leads" do
    assert_equal [], @tracker.matcher_people
  end
end
