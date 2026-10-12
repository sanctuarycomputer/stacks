require 'test_helper'

class StacksMeetingsProjectMatcherTest < ActiveSupport::TestCase
  Matcher = Stacks::Meetings::ProjectMatcher

  def setup
    Stacks::AI.stubs(:configured?).returns(true)
    Matcher.stubs(:enabled?).returns(true)
    @tracker = tracker!("Harvey Staff Augmentation")
  end

  def meeting!(title: "Harvey weekly sync", started_at: 2.days.ago)
    Meeting.create!(title: title, started_at: started_at, meet_source: :meet_api)
  end

  def doc!(meeting, source: :meet, title: meeting.title, content_hash: SecureRandom.hex(8),
           chunks: ["We reviewed the Harvey staging build."], speaker: "Sam Lead")
    d = Document.create!(source: source, external_id: SecureRandom.hex(6), title: title,
                         occurred_at: meeting.started_at, content_hash: content_hash, source_record: meeting)
    chunks.each_with_index { |c, i| d.chunks.create!(position: i, content: c, speaker_name: speaker, source: source, occurred_at: meeting.started_at) }
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

  # Runs the matcher once with one stubbed answer and returns the prompt it sent.
  def prompt_sent(result = answer)
    prompt = nil
    Stacks::AI.expects(:extract).once.with { |args| prompt = args[:prompt]; true }.returns(result)
    Matcher.run!
    prompt
  end

  test "a recent meeting with an eligible document is matched once" do
    m = meeting!
    doc!(m)
    Stacks::AI.expects(:extract).once.returns(answer)
    stats = Matcher.run!
    link = MeetingProjectTracker.find_by!(meeting: m, project_tracker: @tracker)
    assert link.llm?
    assert_equal 0.9, link.confidence
    assert_equal "Title names the client.", link.rationale
    scan = m.reload.meeting_project_scan
    assert scan.linked?
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
    Matcher.run!
    Stacks::AI.expects(:extract).never
    assert_equal 0, Matcher.run![:scanned]
  end

  test "confidence under the threshold is no_match" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(confidence: 0.59))
    stats = Matcher.run!
    assert_equal 0, MeetingProjectTracker.count
    assert m.reload.meeting_project_scan.no_match?
    assert_equal 1, stats[:no_match]
  end

  test "confidence exactly at the threshold links" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(confidence: Matcher::CONFIDENCE_THRESHOLD))
    Matcher.run!
    assert_equal [@tracker.id], m.meeting_project_trackers.pluck(:project_tracker_id)
    assert_equal 0.6, m.meeting_project_trackers.first.confidence
    assert m.reload.meeting_project_scan.linked?
  end

  test "a confidence outside 0 to 1 is clamped before it is stored" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(confidence: 5))
    Matcher.run!
    assert_equal 1.0, m.meeting_project_trackers.first.confidence
  end

  test "a very long rationale is stored at 300 characters, on one line" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(rationale: "Names  the\nclient. " + ("x" * 50_000)))
    Matcher.run!
    rationale = m.meeting_project_trackers.first.rationale
    assert_equal 300, rationale.length
    assert rationale.start_with?("Names the client. xxx")
  end

  test "a rationale that is not a string does not raise and is stored as text" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(rationale: { "why" => "Title names the client." }))
    stats = Matcher.run!
    assert_equal 0, stats[:errored]
    assert_equal({ "why" => "Title names the client." }.to_s.squish, m.meeting_project_trackers.first.rationale)
    assert m.reload.meeting_project_scan.linked?
  end

  test "a dry run reports the confidence and rationale as they would be stored" do
    doc!(meeting!)
    Stacks::AI.stubs(:extract).returns(answer(confidence: 5, rationale: "y" * 50_000))
    result = Matcher.run!(dry_run: true)[:results].first
    assert_equal 1.0, result[:confidence]
    assert_equal "y" * 300, result[:rationale]
    Stacks::AI.stubs(:extract).returns(answer(rationale: { "why" => "x" }))
    assert_kind_of String, Matcher.run!(dry_run: true)[:results].first[:rationale]
  end

  test "an empty answer is no_match" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: []))
    Matcher.run!
    assert_equal 0, MeetingProjectTracker.count
    assert m.reload.meeting_project_scan.no_match?
  end

  test "a tracker id the model invents is ignored" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: [@tracker.id, 987_654]))
    Matcher.run!
    assert_equal [@tracker.id], m.meeting_project_trackers.pluck(:project_tracker_id)
  end

  test "an answer of only invented ids is no_match" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: [987_654]))
    Matcher.run!
    assert_equal 0, MeetingProjectTracker.count
    assert m.reload.meeting_project_scan.no_match?
  end

  test "a transcript and its notes cost one call and get one set of links" do
    m = meeting!
    doc!(m)
    doc!(m, source: :gemini_notes)
    Stacks::AI.expects(:extract).once.returns(answer)
    Matcher.run!
    assert_equal 1, MeetingProjectTracker.count
    assert_equal 1, MeetingProjectScan.count
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
    stats = Matcher.run!(dry_run: true)
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
    assert_includes prompt, "n" * Matcher::BODY_CHARS
    assert_not_includes prompt, "n" * (Matcher::BODY_CHARS + 1)
    assert_includes prompt, "t" * Matcher::BODY_CHARS
    assert_not_includes prompt, "t" * (Matcher::BODY_CHARS + 1)
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
    Matcher.run!
    assert_nil m.reload.meeting_project_scan
  end

  test "a meeting older than the window is not sent" do
    doc!(meeting!(started_at: (Matcher::WINDOW + 1.day).ago))
    Stacks::AI.expects(:extract).never
    Matcher.run!
    assert_equal 0, MeetingProjectScan.count
  end

  test "changed content is matched again: llm links the model dropped go, and the scan is refreshed" do
    m = meeting!
    doc = doc!(m, content_hash: "v1")
    other = tracker!("Acme Phase 2")
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: [@tracker.id]))
    Matcher.run!
    first_hash = m.reload.meeting_project_scan.scanned_hash

    doc.update!(content_hash: "v2")
    Stacks::AI.expects(:extract).once.returns(answer(tracker_ids: [other.id], rationale: "Now about Acme."))
    Matcher.run!

    assert_equal [other.id], m.meeting_project_trackers.pluck(:project_tracker_id)
    scan = m.reload.meeting_project_scan
    assert scan.linked?
    assert_not scan.human_locked?, "the matcher's own removals do not lock"
    assert_not_equal first_hash, scan.scanned_hash
    assert_equal m.eligible_content_hash, scan.scanned_hash
  end

  test "changed content that no longer matches drops the llm links" do
    m = meeting!
    doc = doc!(m, content_hash: "v1")
    Stacks::AI.stubs(:extract).returns(answer)
    Matcher.run!
    doc.update!(content_hash: "v2")
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: []))
    Matcher.run!
    assert_equal 0, MeetingProjectTracker.count
    assert m.reload.meeting_project_scan.no_match?
  end

  test "a link to a tracker completed since survives a rescan" do
    m = meeting!
    doc = doc!(m, content_hash: "v1")
    Stacks::AI.stubs(:extract).returns(answer)
    Matcher.run!
    link = MeetingProjectTracker.find_by!(meeting: m, project_tracker: @tracker)

    @tracker.update_columns(work_completed_at: 1.day.ago)
    doc.update!(content_hash: "v2")
    Stacks::AI.expects(:extract).once.returns(answer(tracker_ids: []))
    stats = Matcher.run!

    assert MeetingProjectTracker.exists?(link.id), "the tracker is no longer a candidate, so the model could not have returned it"
    scan = m.reload.meeting_project_scan
    assert scan.linked?
    assert_equal m.eligible_content_hash, scan.scanned_hash
    assert_equal 1, stats[:linked]
  end

  test "a person's link is never removed, even when the scan is not locked" do
    m = meeting!
    doc!(m)
    other = tracker!("Acme Phase 2")
    human = MeetingProjectTracker.new(meeting: m, project_tracker: @tracker, matched_by: :human)
    human.via_matcher = true # saved without taking the lock
    human.save!
    assert human.human?
    assert_nil m.reload.meeting_project_scan

    Stacks::AI.expects(:extract).once.returns(answer(tracker_ids: [other.id]))
    Matcher.run!

    assert MeetingProjectTracker.exists?(human.id)
    assert human.reload.human?
    assert_equal [@tracker.id, other.id].sort, m.meeting_project_trackers.pluck(:project_tracker_id).sort
    assert_not m.reload.meeting_project_scan.human_locked?
  end

  test "the scan's hash is taken from the documents the prompt was built from, not read again" do
    m = meeting!
    transcript = doc!(m, content_hash: "v1")
    notes = doc!(m, source: :gemini_notes, content_hash: "n1")
    expected = Meeting.content_hash_for([transcript, notes])
    # A second read could see a document that changed after the prompt's were loaded.
    Meeting.any_instance.expects(:eligible_content_hash).never
    Stacks::AI.expects(:extract).once.returns(answer)
    Matcher.run!
    assert_equal expected, MeetingProjectScan.find_by!(meeting_id: m.id).scanned_hash
  end

  test "a matched meeting that stops being readable loses its llm links and scan, with no model call" do
    m = meeting!
    doc = doc!(m)
    Stacks::AI.stubs(:extract).returns(answer)
    Matcher.run!
    exclude!(doc)
    Stacks::AI.expects(:extract).never
    stats = Matcher.run!
    assert_equal 1, stats[:removed]
    assert_equal 0, MeetingProjectTracker.count
    assert_equal 0, MeetingProjectScan.count
  end

  test "an unreadable meeting outside the window is cleaned up too" do
    m = meeting!(started_at: 40.days.ago)
    doc = doc!(m)
    link = MeetingProjectTracker.new(meeting: m, project_tracker: @tracker, rationale: "r")
    link.via_matcher = true
    link.save!
    MeetingProjectScan.create!(meeting: m, outcome: :linked, scanned_at: 30.days.ago, scanned_hash: m.eligible_content_hash)
    exclude!(doc)
    assert_equal 1, Matcher.run![:removed]
    assert_equal 0, MeetingProjectTracker.count
  end

  test "a human-locked scan is never rematched and a human link is never removed" do
    m = meeting!
    doc = doc!(m, content_hash: "v1")
    link = MeetingProjectTracker.create!(meeting: m, project_tracker: @tracker)
    assert link.human?
    doc.update!(content_hash: "v2")
    Stacks::AI.expects(:extract).never
    Matcher.run!
    assert MeetingProjectTracker.exists?(link.id)

    exclude!(doc)
    assert_equal 0, Matcher.run![:removed]
    assert MeetingProjectTracker.exists?(link.id)
    assert m.reload.meeting_project_scan.human_locked?
  end

  test "a person locking the meeting while the model is answering wins" do
    m = meeting!
    doc!(m)
    Stacks::AI.expects(:extract).once.with { |_|
      MeetingProjectScan.create!(meeting: m, outcome: :no_match, human_locked: true, scanned_at: Time.zone.now, scanned_hash: "person")
      true
    }.returns(answer)
    Matcher.run!
    assert_equal 0, MeetingProjectTracker.count
    scan = m.reload.meeting_project_scan
    assert scan.no_match?
    assert_equal "person", scan.scanned_hash
  end

  test "a no_match meeting is retried when a tracker was created after its scan" do
    m = meeting!
    doc!(m)
    MeetingProjectScan.create!(meeting: m, outcome: :no_match, scanned_at: 1.day.ago, scanned_hash: m.eligible_content_hash)
    Stacks::AI.expects(:extract).once.returns(answer)
    Matcher.run!
    assert m.reload.meeting_project_scan.linked?
  end

  test "a no_match meeting is not retried when no tracker is newer than its scan" do
    m = meeting!
    doc!(m)
    @tracker.update_columns(created_at: 3.days.ago)
    MeetingProjectScan.create!(meeting: m, outcome: :no_match, scanned_at: 1.day.ago, scanned_hash: m.eligible_content_hash)
    Stacks::AI.expects(:extract).never
    Matcher.run!
  end

  test "a no_match meeting is not retried when the only newer tracker is one of our own companies'" do
    m = meeting!
    doc!(m)
    MeetingProjectScan.create!(meeting: m, outcome: :no_match, scanned_at: 1.day.ago, scanned_hash: m.eligible_content_hash)
    # As in the internal-tracker test below: every open tracker reads as internal.
    ProjectTracker.any_instance.stubs(:internal_client?).returns(true)
    Stacks::AI.expects(:extract).never
    assert_equal 0, Matcher.run![:scanned]
  end

  test "a no_match meeting is not retried when the only newer tracker is already completed" do
    m = meeting!
    doc!(m)
    @tracker.update_columns(created_at: 3.days.ago)
    tracker!("Finished Project", work_completed_at: 1.hour.ago)
    MeetingProjectScan.create!(meeting: m, outcome: :no_match, scanned_at: 1.day.ago, scanned_hash: m.eligible_content_hash)
    Stacks::AI.expects(:extract).never
    assert_equal 0, Matcher.run![:scanned]
  end

  test "a linked meeting is not retried just because a tracker is new" do
    m = meeting!
    doc!(m)
    MeetingProjectScan.create!(meeting: m, outcome: :linked, scanned_at: 1.day.ago, scanned_hash: m.eligible_content_hash)
    Stacks::AI.expects(:extract).never
    Matcher.run!
  end

  test "a tracker for one of our own companies is not a candidate" do
    # Every open tracker reads as internal here; unstubbed, a tracker with no
    # Forecast projects is client work, which is what every other test relies on.
    ProjectTracker.any_instance.stubs(:internal_client?).returns(true)
    meeting = meeting!
    doc!(meeting)
    Stacks::AI.expects(:extract).with { |args| @prompt = args[:prompt]; true }.returns(answer)
    Stacks::Meetings::ProjectMatcher.run!
    assert_not_includes @prompt, "id #{@tracker.id}:"
    assert_equal 0, MeetingProjectTracker.count, "an internal tracker's id is not accepted either"
    assert_equal "no_match", meeting.reload.meeting_project_scan.outcome
  end

  test "a completed tracker is not a candidate" do
    done = tracker!("Finished Project", work_completed_at: 1.month.ago)
    doc!(meeting!)
    prompt = prompt_sent(answer(tracker_ids: [done.id]))
    assert_includes prompt, "- id #{@tracker.id}: Harvey Staff Augmentation"
    assert_not_includes prompt, "id #{done.id}:"
    assert_not_includes prompt, "Finished Project"
    assert_equal 0, MeetingProjectTracker.count, "a completed tracker's id is not accepted either"
  end

  test "the prompt lists each candidate tracker with its people" do
    ProjectTracker.any_instance.stubs(:matcher_people).returns(["Sam Lead <sam@sanctuary.computer>"])
    doc!(meeting!, speaker: nil)
    line = prompt_sent.lines.find { |l| l.include?("- id #{@tracker.id}:") }
    assert_includes line, "Harvey Staff Augmentation"
    assert_includes line, "Sam Lead <sam@sanctuary.computer>"
  end

  test "an AI error on one meeting is counted, leaves no scan, and the run goes on" do
    newer = meeting!(started_at: 1.day.ago)
    older = meeting!(started_at: 3.days.ago)
    doc!(newer)
    doc!(older)
    Stacks::AI.stubs(:extract).raises(Stacks::AI::Error, "boom").then.returns(answer)
    stats = Matcher.run!
    assert_equal 1, stats[:errored]
    assert_equal 2, stats[:scanned]
    assert_nil newer.reload.meeting_project_scan
    assert older.reload.meeting_project_scan.linked?
  end

  test "a network error the provider does not wrap is handled the same way" do
    m = meeting!
    doc!(m)
    Stacks::AI.stubs(:extract).raises(Net::ReadTimeout)
    stats = nil
    assert_nothing_raised { stats = Matcher.run! }
    assert_equal 1, stats[:errored]
    assert_nil m.reload.meeting_project_scan
  end

  test "switched off, the run does nothing" do
    Matcher.unstub(:enabled?)
    Matcher.stubs(:enabled?).returns(false)
    doc!(meeting!)
    Stacks::AI.expects(:extract).never
    Stacks::AI.expects(:configured?).never
    assert_equal({ skipped_disabled: 1, errored: 0 }, Matcher.run!)
    assert_equal 0, MeetingProjectScan.count
  end

  test "enabled? reads MEETING_MATCHING" do
    Matcher.unstub(:enabled?)
    ENV.stubs(:[]).returns(nil)
    ENV.stubs(:[]).with("MEETING_MATCHING").returns(" On ")
    assert Matcher.enabled?
    ENV.stubs(:[]).with("MEETING_MATCHING").returns("")
    assert_not Matcher.enabled?
  end

  test "a dry run ignores the switch, calls the model and saves nothing" do
    Matcher.unstub(:enabled?)
    Matcher.stubs(:enabled?).returns(false)
    m = meeting!
    doc!(m)
    Stacks::AI.expects(:extract).once.returns(answer)
    stats = Matcher.run!(dry_run: true)
    assert_equal 0, MeetingProjectTracker.count
    assert_equal 0, MeetingProjectScan.count
    assert_equal [{ meeting_id: m.id, title: "Harvey weekly sync", tracker_ids: [@tracker.id],
                    confidence: 0.9, rationale: "Title names the client." }], stats[:results]
    assert_equal 1, stats[:scanned]
  end

  test "a dry run reports no tracker ids for an answer that would not be saved" do
    doc!(meeting!)
    Stacks::AI.stubs(:extract).returns(answer(tracker_ids: [@tracker.id, 987_654], confidence: 0.4))
    assert_equal [], Matcher.run!(dry_run: true)[:results].first[:tracker_ids]
  end

  test "a dry run does not clean up unreadable meetings" do
    m = meeting!
    doc = doc!(m)
    Stacks::AI.stubs(:extract).returns(answer)
    Matcher.run!
    exclude!(doc)
    Matcher.run!(dry_run: true)
    assert_equal 1, MeetingProjectTracker.count
    assert_equal 1, MeetingProjectScan.count
  end

  test "without an AI key nothing is called and nothing is written" do
    Stacks::AI.stubs(:configured?).returns(false)
    doc!(meeting!)
    doc!(meeting!)
    Stacks::AI.expects(:extract).never
    stats = Matcher.run!
    assert_equal 2, stats[:skipped_no_key]
    assert_equal 0, stats[:errored]
    assert_equal 0, MeetingProjectScan.count
  end

  test "limit caps the model calls, newest meetings first" do
    oldest = meeting!(started_at: 5.days.ago)
    newest = meeting!(started_at: 1.day.ago)
    middle = meeting!(started_at: 3.days.ago)
    [oldest, newest, middle].each { |m| doc!(m) }
    Stacks::AI.expects(:extract).twice.returns(answer)
    Matcher.run!(limit: 2)
    assert_equal [newest.id, middle.id].sort, MeetingProjectScan.pluck(:meeting_id).sort
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
