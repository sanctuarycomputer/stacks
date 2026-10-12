require 'test_helper'

class MeetingScanTest < ActiveSupport::TestCase
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

  def scan!(meeting, **attrs)
    MeetingScan.create!({ meeting: meeting, outcome: :linked, scanned_at: 1.day.ago }.merge(attrs))
  end

  def join_rows
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM meetings_project_trackers").to_i
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

  test "content_hash_for hashes loaded documents the way eligible_content_hash does" do
    m = meeting!
    a = doc!(m, content_hash: "a1")
    b = doc!(m, source: :gemini_notes, content_hash: "b1")
    assert_equal m.eligible_content_hash, Meeting.content_hash_for([b, a])
    assert_equal Digest::SHA256.hexdigest("#{a.id}:a1|#{b.id}:b1"), Meeting.content_hash_for([a, b])
    assert_nil Meeting.content_hash_for([])
  end

  test "a tracker has many meetings and a meeting has many trackers, with no join model" do
    m = meeting!
    t = tracker!("Harvey")
    t.meetings << m
    assert_equal [m.id], t.reload.meetings.pluck(:id)
    assert_equal [t.id], m.reload.project_trackers.pluck(:id)
    assert_equal :has_and_belongs_to_many, ProjectTracker.reflect_on_association(:meetings).macro
    assert_equal :has_and_belongs_to_many, Meeting.reflect_on_association(:project_trackers).macro
    # Nothing else on either side: no join model and no has_many to one.
    assert_equal [:meetings], ProjectTracker.reflect_on_all_associations.map(&:name).grep(/meeting/)
    assert_equal [:meeting_scan, :project_trackers], Meeting.reflect_on_all_associations.map(&:name).grep(/scan|tracker/).sort
    models = Dir[Rails.root.join("app/models/meeting*.rb")].map { |f| File.basename(f, ".rb") }.sort
    assert_equal %w[meeting meeting_participant meeting_scan meeting_transcript_segment], models
  end

  test "the join table holds a meeting and tracker pair once" do
    m = meeting!
    t = tracker!("Harvey")
    m.project_trackers << t
    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.connection.execute(
        "INSERT INTO meetings_project_trackers (meeting_id, project_tracker_id) VALUES (#{m.id}, #{t.id})")
    end
  end

  test "a scan belongs to one meeting, and a meeting has one scan" do
    m = meeting!
    scan = scan!(m, outcome: :out_of_scope)
    assert scan.out_of_scope?
    assert_equal scan, m.reload.meeting_scan
    assert_equal({ "linked" => 0, "no_match" => 1, "out_of_scope" => 2 }, MeetingScan.outcomes)
    assert_raises(ActiveRecord::RecordNotUnique) { scan!(m) }
    assert_not MeetingScan.new(meeting: meeting!, outcome: :linked).valid?, "scanned_at is required"
  end

  # A person's changes

  test "link_project! adds the tracker and locks a new scan as linked" do
    m = meeting!
    doc!(m)
    t = tracker!("Harvey")
    m.link_project!(t)
    assert_equal [t.id], m.reload.project_trackers.pluck(:id)
    scan = m.meeting_scan
    assert scan.human_locked?
    assert scan.linked?
    assert_equal m.eligible_content_hash, scan.scanned_hash
    assert_in_delta Time.zone.now, scan.scanned_at, 5.seconds
  end

  test "link_project! twice leaves one link" do
    m = meeting!
    doc!(m)
    t = tracker!("Harvey")
    m.link_project!(t)
    assert_nothing_raised { Meeting.find(m.id).link_project!(t) }
    assert_equal 1, join_rows
    assert m.reload.meeting_scan.linked?
  end

  test "link_project! locks an existing scan without touching its hash, reason or confidence" do
    m = meeting!
    doc!(m)
    scan!(m, outcome: :no_match, scanned_hash: "older", rationale: "Internal standup.", confidence: 0.2)
    m.link_project!(tracker!("Harvey"))
    scan = m.reload.meeting_scan
    assert scan.human_locked?
    assert scan.linked?
    assert_equal "older", scan.scanned_hash
    assert_equal "Internal standup.", scan.rationale
    assert_equal 0.2, scan.confidence
    assert_in_delta Time.zone.now, scan.scanned_at, 5.seconds
  end

  test "link_project! raises, and writes nothing, for a meeting with no document in the corpus" do
    m = meeting!
    exclude!(doc!(m))
    error = assert_raises(ActiveRecord::RecordInvalid) { m.link_project!(tracker!("Harvey")) }
    assert_includes error.message, "has no document in the Stacks corpus"
    assert_equal 0, join_rows
    assert_equal 0, MeetingScan.count
  end

  test "unlink_project! removes the tracker and locks the scan: linked while another remains, then no_match" do
    m = meeting!
    doc!(m)
    one = tracker!("Harvey")
    two = tracker!("Acme")
    m.project_trackers << [one, two]
    scan!(m, scanned_hash: "sweep", rationale: "r", confidence: 0.9)

    m.unlink_project!(one)
    scan = m.reload.meeting_scan
    assert_equal [two.id], m.project_trackers.pluck(:id)
    assert scan.human_locked?
    assert scan.linked?
    assert_equal "sweep", scan.scanned_hash

    m.unlink_project!(two)
    assert scan.reload.no_match?
    assert scan.human_locked?
    assert_equal 0, join_rows
  end

  test "unlink_project! of a tracker the meeting does not have still locks, and creates the scan if there is none" do
    m = meeting!
    doc!(m)
    assert_nothing_raised { m.unlink_project!(tracker!("Harvey")) }
    scan = m.reload.meeting_scan
    assert scan.human_locked?
    assert scan.no_match?
    assert_equal m.eligible_content_hash, scan.scanned_hash
  end

  test "writing the join directly, as the sweep does, locks nothing" do
    m = meeting!
    doc!(m)
    m.project_trackers << tracker!("Harvey")
    assert_nil m.reload.meeting_scan
  end

  # Destroy paths

  test "destroying a meeting removes its links and its scan" do
    m = meeting!
    doc!(m)
    m.link_project!(tracker!("Harvey"))
    assert_nothing_raised { m.reload.destroy }
    assert_equal 0, join_rows
    assert_equal 0, MeetingScan.count
  end

  test "destroying a tracker leaves a scan with no trackers as no_match, and one with another tracker as linked" do
    gone = tracker!("Harvey")
    stays = tracker!("Acme")
    emptied = meeting!
    emptied.project_trackers << gone
    scan!(emptied, scanned_hash: "a")
    still_linked = meeting!
    still_linked.project_trackers << [gone, stays]
    scan!(still_linked, scanned_hash: "b")
    untouched = meeting!
    untouched.project_trackers << stays
    scan!(untouched, scanned_hash: "c")
    old = meeting!
    scan!(old, outcome: :out_of_scope)

    assert_nothing_raised { gone.reload.destroy }

    assert_equal 2, join_rows
    scan = emptied.reload.meeting_scan
    assert scan.no_match?
    assert_not scan.human_locked?, "a tracker going away is not a person's correction"
    assert_equal "a", scan.scanned_hash
    assert still_linked.reload.meeting_scan.linked?
    assert untouched.reload.meeting_scan.linked?
    assert old.reload.meeting_scan.out_of_scope?
  end

  test "destroying a tracker keeps a person's lock, and the locked scan is no_match once it has no trackers" do
    gone = tracker!("Harvey")
    m = meeting!
    doc!(m)
    m.link_project!(gone)
    scan = m.reload.meeting_scan
    assert scan.human_locked?
    assert scan.linked?

    gone.reload.destroy

    assert scan.reload.human_locked?
    assert scan.no_match?
  end

  # ETL absorb

  test "absorb_project_matches_from! moves trackers and the scan, skipping a tracker the survivor has" do
    survivor = meeting!(title: "Harvey sync")
    doc!(survivor)
    standalone = meeting!(title: "Harvey sync notes")
    doc!(standalone, source: :gemini_notes)
    shared = tracker!("Harvey")
    other = tracker!("Acme")
    survivor.project_trackers << shared
    standalone.project_trackers << [shared, other]
    scan!(standalone, scanned_hash: "standalone", human_locked: true, rationale: "SECRET NOTES TEXT", confidence: 0.95)

    survivor.absorb_project_matches_from!(standalone)

    assert_equal [shared.id, other.id].sort, survivor.reload.project_trackers.pluck(:id).sort
    scan = survivor.meeting_scan
    assert scan.human_locked?, "the moved scan keeps its lock"
    assert scan.linked?
    assert_nil scan.scanned_hash
    assert_nil scan.rationale
    assert_nil scan.confidence
    assert_nothing_raised { standalone.destroy }
    assert_equal 2, join_rows
    assert_equal 1, MeetingScan.count
    assert_equal survivor.id, MeetingScan.first.meeting_id
  end

  test "absorb_project_matches_from! keeps the survivor's scan, carries a lock over and blanks what it said" do
    survivor = meeting!
    doc!(survivor)
    standalone = meeting!
    doc!(standalone, source: :gemini_notes)
    scan!(survivor, outcome: :no_match, scanned_hash: "mine", rationale: "Internal standup.", confidence: 0.3)
    scan!(standalone, scanned_hash: "theirs", human_locked: true, rationale: "SECRET NOTES TEXT", confidence: 0.9)
    survivor.absorb_project_matches_from!(standalone)
    scan = survivor.reload.meeting_scan
    assert_nil scan.scanned_hash, "the survivor's documents changed, so its old hash no longer stands"
    assert_nil scan.rationale
    assert_nil scan.confidence
    assert scan.human_locked?
    assert scan.no_match?
    assert MeetingScan.exists?(meeting_id: standalone.id), "the other scan is left for the destroy"
  end

  test "absorb_project_matches_from! never carries a reason over, and leaves an unlocked scan due for a rescan" do
    survivor = meeting!
    doc!(survivor)
    scan!(survivor, outcome: :no_match, scanned_hash: survivor.eligible_content_hash)
    standalone = meeting!
    doc!(standalone, source: :gemini_notes)
    standalone.project_trackers << tracker!("Harvey")
    scan!(standalone, scanned_hash: "theirs", rationale: "SECRET NOTES TEXT", confidence: 0.9)

    survivor.absorb_project_matches_from!(standalone)
    standalone.destroy

    scan = survivor.reload.meeting_scan
    assert_nil scan.scanned_hash
    assert_nil scan.rationale
    assert_not scan.human_locked?
    assert scan.linked?, "the survivor now has a tracker"
    assert_equal 0, MeetingScan.where("rationale LIKE ?", "%SECRET%").count
  end

  test "absorb_project_matches_from! leaves a moved scan saying what the survivor now has" do
    survivor = meeting!
    doc!(survivor)
    survivor.project_trackers << tracker!("Harvey")
    standalone = meeting!
    doc!(standalone, source: :gemini_notes)
    scan!(standalone, outcome: :no_match, scanned_hash: "theirs", rationale: "Nothing matched.", confidence: 0.1)

    survivor.absorb_project_matches_from!(standalone)

    scan = survivor.reload.meeting_scan
    assert scan.linked?
    assert_nil scan.scanned_hash
    assert_nil scan.rationale
    assert_nil scan.confidence
  end

  test "absorb_project_matches_from! with no trackers on either side leaves the survivor's scan no_match" do
    survivor = meeting!
    doc!(survivor)
    scan!(survivor, outcome: :no_match, scanned_hash: "mine")
    standalone = meeting!
    doc!(standalone, source: :gemini_notes)
    survivor.absorb_project_matches_from!(standalone)
    scan = survivor.reload.meeting_scan
    assert scan.no_match?
    assert_nil scan.scanned_hash
  end

  test "absorb_project_matches_from! with no scan on either side makes none" do
    survivor = meeting!
    standalone = meeting!
    standalone.project_trackers << tracker!("Harvey")
    survivor.absorb_project_matches_from!(standalone)
    assert_equal 1, survivor.reload.project_trackers.count
    assert_equal 0, MeetingScan.count
  end
end
