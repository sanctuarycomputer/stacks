require 'test_helper'

class MeetingProjectMatchTest < ActiveSupport::TestCase
  def meeting!(title: "Harvey weekly sync", started_at: 2.days.ago)
    Meeting.create!(title: title, started_at: started_at, meet_source: :meet_api)
  end

  def doc!(meeting, source: :meet, content_hash: SecureRandom.hex(8), chunks: ["We reviewed the Harvey staging build."], speaker: "Sam Lead")
    d = Document.create!(source: source, external_id: SecureRandom.hex(6), title: meeting.title,
                         occurred_at: meeting.started_at, content_hash: content_hash, source_record: meeting)
    chunks.each_with_index { |c, i| d.chunks.create!(position: i, content: c, speaker_name: speaker, source: source, occurred_at: meeting.started_at) }
    d
  end

  def exclude!(doc)
    doc.update_columns(excluded: Document.excludeds[:manually_excluded])
  end

  def tracker!(name)
    ProjectTracker.new(name: name).tap { |t| t.save!(validate: false) }
  end

  # A link written the way the matcher writes it: no human lock.
  def matcher_link!(meeting, tracker, confidence: 0.9)
    link = MeetingProjectTracker.new(meeting: meeting, project_tracker: tracker, confidence: confidence, rationale: "r")
    link.via_matcher = true
    link.save!
    link
  end

  test "eligible_documents returns only corpus-eligible documents" do
    m = meeting!
    transcript = doc!(m)
    notes = doc!(m, source: :gemini_notes)
    exclude!(transcript)
    assert_equal [notes.id], m.eligible_documents.pluck(:id)
  end

  test "eligible_content_hash is nil when no document is eligible" do
    m = meeting!
    assert_nil m.eligible_content_hash
    exclude!(doc!(m))
    assert_nil m.eligible_content_hash
  end

  test "eligible_content_hash follows the eligible documents and not their order" do
    m = meeting!
    a = doc!(m, content_hash: "a1")
    b = doc!(m, source: :gemini_notes, content_hash: "b1")
    both = m.eligible_content_hash
    assert_equal Digest::SHA256.hexdigest("#{a.id}:a1|#{b.id}:b1"), both
    # The same documents loaded in the other order hash the same.
    Meeting.any_instance.stubs(:documents).returns(Document.where(source_record: m).order(id: :desc))
    assert_equal both, Meeting.find(m.id).eligible_content_hash
    Meeting.any_instance.unstub(:documents)

    a.update!(content_hash: "a2")
    changed = m.eligible_content_hash
    assert_not_equal both, changed

    exclude!(b)
    assert_not_equal changed, m.eligible_content_hash
  end

  test "a link is unique per meeting and tracker" do
    m = meeting!
    doc!(m)
    t = tracker!("Harvey")
    matcher_link!(m, t)
    dup = MeetingProjectTracker.new(meeting: m, project_tracker: t)
    dup.via_matcher = true
    assert_not dup.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "a link saved by a person is human and locks the meeting's scan as linked" do
    m = meeting!
    doc!(m)
    link = MeetingProjectTracker.create!(meeting: m, project_tracker: tracker!("Harvey"))
    assert link.human?
    scan = m.reload.meeting_project_scan
    assert scan.human_locked?
    assert scan.linked?
    assert_equal m.eligible_content_hash, scan.scanned_hash
  end

  test "a person's link locks an existing scan without touching its scanned_hash" do
    m = meeting!
    doc!(m)
    MeetingProjectScan.create!(meeting: m, outcome: :no_match, scanned_at: 1.day.ago, scanned_hash: "older")
    MeetingProjectTracker.create!(meeting: m, project_tracker: tracker!("Harvey"))
    scan = m.reload.meeting_project_scan
    assert scan.human_locked?
    assert scan.linked?
    assert_equal "older", scan.scanned_hash
  end

  test "a link saved by the matcher stays llm and does not lock" do
    m = meeting!
    doc!(m)
    link = matcher_link!(m, tracker!("Harvey"))
    assert link.llm?
    assert_nil m.reload.meeting_project_scan
  end

  test "a person cannot link a meeting with no document in the corpus" do
    m = meeting!
    exclude!(doc!(m))
    link = MeetingProjectTracker.new(meeting: m, project_tracker: tracker!("Harvey"))
    assert_not link.valid?
    assert_includes link.errors[:meeting].join, "has no document in the Stacks corpus"
    assert_equal 0, MeetingProjectScan.count
  end

  test "destroying a link by hand locks the scan: linked while another link remains, then no_match" do
    m = meeting!
    doc!(m)
    one = matcher_link!(m, tracker!("Harvey"))
    two = matcher_link!(m, tracker!("Acme"))
    MeetingProjectTracker.find(one.id).destroy
    scan = m.reload.meeting_project_scan
    assert scan.human_locked?
    assert scan.linked?
    MeetingProjectTracker.find(two.id).destroy
    assert scan.reload.no_match?
    assert scan.human_locked?
  end

  test "destroying a link as the matcher does not lock" do
    m = meeting!
    doc!(m)
    link = matcher_link!(m, tracker!("Harvey"))
    link.via_matcher = true
    link.destroy
    assert_nil m.reload.meeting_project_scan
  end

  test "destroying a meeting removes its links and its scan" do
    m = meeting!
    doc!(m)
    MeetingProjectTracker.create!(meeting: m, project_tracker: tracker!("Harvey"))
    assert_nothing_raised { m.reload.destroy }
    assert_equal 0, MeetingProjectTracker.count
    assert_equal 0, MeetingProjectScan.count
  end

  test "destroying a tracker removes its links without raising or locking" do
    m = meeting!
    doc!(m)
    t = tracker!("Harvey")
    matcher_link!(m, t)
    assert_nothing_raised { t.reload.destroy }
    assert_equal 0, MeetingProjectTracker.count
    assert_nil m.reload.meeting_project_scan
  end

  test "before the migration has run, destroying a meeting or a tracker touches neither new table" do
    m = meeting!
    t = tracker!("Harvey")
    MeetingProjectTracker.stubs(:table_exists?).returns(false)
    MeetingProjectScan.stubs(:table_exists?).returns(false)
    MeetingProjectTracker.expects(:where).never
    MeetingProjectScan.expects(:where).never
    assert_nothing_raised { m.destroy }
    assert_nothing_raised { t.destroy }
    assert_not Meeting.exists?(m.id)
    assert_not ProjectTracker.exists?(t.id)
  end

  test "absorb_project_matches_from! moves links and the scan, skipping a tracker the survivor has" do
    survivor = meeting!(title: "Harvey sync")
    doc!(survivor)
    standalone = meeting!(title: "Harvey sync notes")
    doc!(standalone, source: :gemini_notes)
    shared = tracker!("Harvey")
    other = tracker!("Acme")
    kept = matcher_link!(survivor, shared, confidence: 0.7)
    matcher_link!(standalone, shared, confidence: 0.95)
    moved = matcher_link!(standalone, other)
    MeetingProjectScan.create!(meeting: standalone, outcome: :linked, scanned_at: 1.day.ago,
                               scanned_hash: "standalone", human_locked: true)

    survivor.absorb_project_matches_from!(standalone)

    assert_equal [shared.id, other.id].sort, survivor.reload.meeting_project_trackers.pluck(:project_tracker_id).sort
    assert_equal survivor.id, moved.reload.meeting_id
    assert_equal 0.7, kept.reload.confidence
    scan = survivor.meeting_project_scan
    assert_equal "standalone", scan.scanned_hash
    assert scan.human_locked?, "the moved scan keeps its lock"
    assert_nothing_raised { standalone.reload.destroy }
    assert_equal 2, MeetingProjectTracker.count
    assert_equal 1, MeetingProjectScan.count
  end

  test "absorb_project_matches_from! keeps the survivor's scan and carries a lock over" do
    survivor = meeting!
    doc!(survivor)
    standalone = meeting!
    doc!(standalone, source: :gemini_notes)
    MeetingProjectScan.create!(meeting: survivor, outcome: :no_match, scanned_at: 1.day.ago, scanned_hash: "mine")
    MeetingProjectScan.create!(meeting: standalone, outcome: :linked, scanned_at: 1.day.ago,
                               scanned_hash: "theirs", human_locked: true)
    survivor.absorb_project_matches_from!(standalone)
    scan = survivor.reload.meeting_project_scan
    assert_equal "mine", scan.scanned_hash
    assert scan.human_locked?
    assert MeetingProjectScan.exists?(meeting_id: standalone.id), "the other scan is left for the destroy"
  end
end
