require 'test_helper'

# The "Meeting Matches" page: which project tracker(s) the nightly matcher
# decided each Meet meeting was about, and a person's corrections to that.
class AdminMeetingMatchesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "matchadmin#{SecureRandom.hex(4)}@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345',
      roles: ['admin']
    )
    sign_in @admin
    @tracker = tracker!("Harvey Staff Augmentation")
  end

  def tracker!(name)
    ProjectTracker.new(name: name).tap { |t| t.save!(validate: false) }
  end

  def meeting!(title, started_at: 2.days.ago)
    Meeting.create!(title: title, started_at: started_at, meet_source: :meet_api)
  end

  def doc!(meeting, source: :meet, title: meeting.title, url: nil)
    Document.create!(source: source, external_id: SecureRandom.hex(6), title: title, url: url,
                     occurred_at: meeting.started_at, content_hash: SecureRandom.hex(8), source_record: meeting)
  end

  def exclude!(doc)
    doc.update_columns(excluded: Document.excludeds[:manually_excluded])
  end

  # A meeting as the matcher leaves it: links (when it matched) and a scan.
  def matched!(title, tracker: @tracker, confidence: 0.9, rationale: "Title names the client.", started_at: 2.days.ago)
    m = meeting!(title, started_at: started_at)
    doc!(m)
    if tracker
      link = MeetingProjectTracker.new(meeting: m, project_tracker: tracker, confidence: confidence, rationale: rationale)
      link.via_matcher = true
      link.save!
    end
    MeetingProjectScan.create!(meeting: m, outcome: tracker ? :linked : :no_match, scanned_at: 1.hour.ago,
                               scanned_hash: m.eligible_content_hash)
    m
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  def row_for(meeting)
    page.at_css("#meeting_project_scan_#{meeting.meeting_project_scan.id}")
  end

  test "the index lists a matched meeting with its tracker, confidence and reason" do
    m = matched!("Harvey weekly sync")
    m.documents.first.update!(url: "https://docs.example/transcript-1")
    get admin_meeting_project_scans_path(scope: "all")
    assert_response :success
    row = row_for(m)
    assert_includes row.text, "Harvey weekly sync"
    assert_includes row.text, "Harvey Staff Augmentation"
    assert_includes row.text, "90%"
    assert_includes row.text, "Title names the client."
    assert_includes row.text, "Stacks (automatic)"
    assert_equal "_blank", row.at_css("a[href='https://docs.example/transcript-1']")["target"]
    assert row.at_css("a[href='#{admin_project_tracker_path(@tracker)}']")
    remove = row.at_css("a[href='#{admin_meeting_project_tracker_path(m.meeting_project_trackers.first)}']")
    assert_equal "delete", remove["data-method"]
    assert remove["data-confirm"].present?
    assert row.at_css("a[href='#{new_admin_meeting_project_tracker_path(meeting_id: m.id)}']")
    assert_includes page.css("#tabs, .header").text, "Meeting Matches"
  end

  test "Needs Review is the default and holds unmatched and unsure meetings only" do
    none = matched!("Studio standup", tracker: nil)
    unsure = matched!("Maybe Harvey", confidence: 0.7)
    sure = matched!("Surely Harvey", confidence: 0.95)
    locked = matched!("Corrected by a person", tracker: nil)
    locked.meeting_project_scan.update!(human_locked: true)

    get admin_meeting_project_scans_path
    assert_response :success
    assert_includes response.body, "Studio standup"
    assert_includes response.body, "Maybe Harvey"
    assert_not_includes response.body, "Surely Harvey"
    assert_not_includes response.body, "Corrected by a person"

    get admin_meeting_project_scans_path(scope: "all")
    [none, unsure, sure, locked].each { |m| assert row_for(m), "expected #{m.title} under All" }
    assert_includes row_for(locked).text, "A person"

    get admin_meeting_project_scans_path(scope: "linked")
    assert_equal [unsure, sure].map { |m| row_for(m).present? }, [true, true]
    assert_nil row_for(none)

    get admin_meeting_project_scans_path(scope: "no_match")
    assert row_for(none)
    assert_nil row_for(sure)
  end

  test "meetings are listed newest first" do
    matched!("Older meeting", started_at: 5.days.ago)
    matched!("Newer meeting", started_at: 1.day.ago)
    matched!("Middle meeting", started_at: 3.days.ago)
    get admin_meeting_project_scans_path(scope: "all")
    body = response.body
    assert_operator body.index("Newer meeting"), :<, body.index("Middle meeting")
    assert_operator body.index("Middle meeting"), :<, body.index("Older meeting")
  end

  test "a meeting with no eligible document is listed nowhere and none of its text is shown" do
    private_tracker = tracker!("Zebra Confidential Engagement")
    m = matched!("PRIVATE-MEETING-TITLE", tracker: private_tracker, confidence: 0.7, rationale: "PRIVATE-RATIONALE about a salary.")
    exclude!(m.documents.first)
    unmatched = matched!("PRIVATE-MEETING-TITLE unmatched", tracker: nil)
    exclude!(unmatched.documents.first)
    listed = matched!("Harvey weekly sync")
    ["needs_review", "linked", "no_match", "all", nil].each do |scope|
      get admin_meeting_project_scans_path(scope: scope)
      assert_response :success
      # Not just its text: the meeting has no row at all, under any scope.
      assert_nil row_for(m), "a private meeting has a row under #{scope.inspect}"
      assert_nil row_for(unmatched), "a private unmatched meeting has a row under #{scope.inspect}"
      assert_not_includes response.body, "Zebra Confidential Engagement"
      assert_not_includes response.body, new_admin_meeting_project_tracker_path(meeting_id: m.id)
      assert_not_includes response.body, "PRIVATE-MEETING-TITLE"
      assert_not_includes response.body, "PRIVATE-RATIONALE"
    end
    get admin_meeting_project_scans_path(scope: "all")
    assert_equal 1, page.css("tr[id^='meeting_project_scan_']").size
    assert row_for(listed)
  end

  test "an excluded notes document's title is never shown, though notes sort first" do
    m = meeting!("PRIVATE NOTES TITLE")
    exclude!(doc!(m, source: :gemini_notes, title: "PRIVATE NOTES TITLE", url: "https://docs.example/private-notes"))
    doc!(m, title: "Harvey weekly sync", url: "https://docs.example/transcript-2")
    MeetingProjectScan.create!(meeting: m, outcome: :no_match, scanned_at: 1.hour.ago, scanned_hash: m.eligible_content_hash)

    get admin_meeting_project_scans_path(scope: "all")
    assert_includes row_for(m).text, "Harvey weekly sync"
    assert row_for(m).at_css("a[href='https://docs.example/transcript-2']")
    assert_not_includes response.body, "PRIVATE NOTES TITLE"
    assert_not_includes response.body, "https://docs.example/private-notes"
  end

  test "a reason written about an absorbed meeting's documents is not shown after the absorb" do
    survivor = matched!("Harvey weekly sync", tracker: nil)
    standalone = meeting!("Harvey weekly sync notes")
    notes = doc!(standalone, source: :gemini_notes)
    link = MeetingProjectTracker.new(meeting: standalone, project_tracker: @tracker, confidence: 0.9, rationale: "SECRET NOTES TEXT")
    link.via_matcher = true
    link.save!
    # The notes are walled off, then the ETL folds the standalone meeting into the survivor.
    exclude!(notes)
    standalone.documents.update_all(source_record_id: survivor.id)
    survivor.absorb_project_matches_from!(standalone)
    standalone.reload.destroy

    get admin_meeting_project_scans_path(scope: "all")
    assert_response :success
    row = row_for(survivor.reload)
    assert_includes row.text, "Harvey Staff Augmentation", "the link itself came along"
    assert_not_includes response.body, "SECRET NOTES TEXT"
  end

  test "the index issues the same number of queries for 2 meetings as for 6" do
    2.times { |i| matched!("Harvey sync #{i}") }
    get admin_meeting_project_scans_path(scope: "all") # warm up
    at_2 = count_queries { get admin_meeting_project_scans_path(scope: "all") }
    assert_equal 2, page.css("tr[id^='meeting_project_scan_']").size
    assert_includes response.body, "Title names the client."

    4.times { |i| matched!("Acme sync #{i}", tracker: tracker!("Acme #{i}")) }
    at_6 = count_queries { get admin_meeting_project_scans_path(scope: "all") }
    assert_equal 6, page.css("tr[id^='meeting_project_scan_']").size
    assert_equal at_2, at_6, "the page issues a query per row"
  end

  test "the title shown comes from an eligible document, never from the meeting row" do
    m = matched!("PRIVATE-TITLE the excluded transcript wrote", rationale: "r")
    exclude!(m.documents.first)
    doc!(m, source: :gemini_notes, title: "Harvey weekly sync")
    untitled = matched!("PRIVATE-TITLE two", tracker: nil, started_at: Time.zone.local(2026, 10, 9, 15))
    untitled.documents.first.update!(title: nil)

    get admin_meeting_project_scans_path(scope: "all")
    assert_includes row_for(m).text, "Harvey weekly sync"
    assert_includes row_for(untitled).text, "Meeting, October 9, 2026"
    assert_not_includes response.body, "PRIVATE-TITLE"
  end

  test "a reason does not outlive the text it was written from" do
    m = meeting!("Harvey weekly sync")
    transcript = doc!(m)
    doc!(m, source: :gemini_notes)
    link = MeetingProjectTracker.new(meeting: m, project_tracker: @tracker, confidence: 0.9, rationale: "QUOTES-THE-TRANSCRIPT")
    link.via_matcher = true
    link.save!
    MeetingProjectScan.create!(meeting: m, outcome: :linked, scanned_at: 1.hour.ago, scanned_hash: m.eligible_content_hash)

    get admin_meeting_project_scans_path(scope: "all")
    assert_includes row_for(m).text, "QUOTES-THE-TRANSCRIPT"

    exclude!(transcript)
    get admin_meeting_project_scans_path(scope: "all")
    assert row_for(m), "the meeting is still listed: its notes are readable"
    assert_not_includes response.body, "QUOTES-THE-TRANSCRIPT"
  end

  test "a model-written reason is escaped" do
    matched!("Harvey weekly sync", rationale: "<script>alert('x')</script> names the client")
    get admin_meeting_project_scans_path(scope: "all")
    assert_not_includes response.body, "<script>alert('x')"
    assert_includes response.body, "&lt;script&gt;alert("
  end

  test "the add-a-project form names the meeting and offers trackers still in flight" do
    m = matched!("Studio standup", tracker: nil)
    done = ProjectTracker.new(name: "Finished Project", work_completed_at: 1.month.ago).tap { |t| t.save!(validate: false) }
    get new_admin_meeting_project_tracker_path(meeting_id: m.id)
    assert_response :success
    assert_includes page.css("form").text, "Studio standup"
    assert_equal m.id.to_s, page.at_css("input[name='meeting_project_tracker[meeting_id]']")["value"]
    options = page.css("select[name='meeting_project_tracker[project_tracker_id]'] option").map(&:text)
    assert_includes options, "Harvey Staff Augmentation"
    assert_not_includes options, done.name
    assert page.at_css("form a[href='#{admin_meeting_project_scans_path}']"), "Cancel goes back to Meeting Matches"
  end

  test "the add-a-project form takes the meeting's title from an eligible document, never from the meeting row" do
    m = matched!("Harvey weekly sync", tracker: nil)
    m.update_columns(title: "PRIVATE ROW TITLE")
    get new_admin_meeting_project_tracker_path(meeting_id: m.id)
    assert_response :success
    assert_includes page.css("form").text, "Harvey weekly sync"
    assert_not_includes response.body, "PRIVATE ROW TITLE"
  end

  test "creating a link by hand makes a human link, locks the scan and returns to the page" do
    m = matched!("Studio standup", tracker: nil)
    post admin_meeting_project_trackers_path,
         params: { meeting_project_tracker: { meeting_id: m.id, project_tracker_id: @tracker.id } }
    assert_redirected_to admin_meeting_project_scans_path
    link = MeetingProjectTracker.find_by!(meeting: m, project_tracker: @tracker)
    assert link.human?
    scan = m.reload.meeting_project_scan
    assert scan.human_locked?
    assert scan.linked?
  end

  test "removing a link locks the scan as no_match and returns to the page" do
    m = matched!("Harvey weekly sync")
    delete admin_meeting_project_tracker_path(m.meeting_project_trackers.first)
    assert_redirected_to admin_meeting_project_scans_path
    assert_equal 0, m.meeting_project_trackers.count
    scan = m.reload.meeting_project_scan
    assert scan.human_locked?
    assert scan.no_match?
  end

  test "the form never shows or links a meeting the corpus cannot read" do
    m = meeting!("PRIVATE-MEETING-TITLE")
    exclude!(doc!(m))

    get new_admin_meeting_project_tracker_path(meeting_id: m.id)
    assert_redirected_to admin_meeting_project_scans_path
    assert_not_includes response.body, "PRIVATE-MEETING-TITLE"
    follow_redirect!
    assert_not_includes response.body, "PRIVATE-MEETING-TITLE"

    post admin_meeting_project_trackers_path,
         params: { meeting_project_tracker: { meeting_id: m.id, project_tracker_id: @tracker.id } }
    assert_redirected_to admin_meeting_project_scans_path
    assert_equal 0, MeetingProjectTracker.count
    assert_equal 0, MeetingProjectScan.count

    get new_admin_meeting_project_tracker_path
    assert_redirected_to admin_meeting_project_scans_path
    get new_admin_meeting_project_tracker_path(meeting_id: 0)
    assert_redirected_to admin_meeting_project_scans_path
  end

  test "a lead can open the page" do
    lead = AdminUser.create!(email: "lead#{SecureRandom.hex(4)}@sanctuary.computer",
                             password: 'password12345', password_confirmation: 'password12345')
    PermissionGrant.create!(admin_user: lead, permission: "lead", granted_by: @admin)
    matched!("Harvey weekly sync")
    sign_out @admin
    sign_in lead
    get admin_meeting_project_scans_path(scope: "all")
    assert_response :success
    assert_includes response.body, "Harvey weekly sync"
  end

  test "a project-scoped lead grantee can neither open the page nor change a match" do
    trainee = AdminUser.create!(email: "trainee#{SecureRandom.hex(4)}@sanctuary.computer",
                                password: 'password12345', password_confirmation: 'password12345')
    PermissionGrant.create!(admin_user: trainee, permission: "lead", subject: @tracker, granted_by: @admin)
    m = matched!("Harvey weekly sync")
    other = tracker!("Acme Phase 2")
    sign_out @admin
    sign_in trainee

    get admin_meeting_project_scans_path(scope: "all")
    assert_not_equal 200, response.status
    assert_not_includes response.body, "Harvey weekly sync"

    get new_admin_meeting_project_tracker_path(meeting_id: m.id)
    assert_not_equal 200, response.status
    assert_not_includes response.body, "Harvey weekly sync"

    post admin_meeting_project_trackers_path,
         params: { meeting_project_tracker: { meeting_id: m.id, project_tracker_id: other.id } }
    assert_not_equal 200, response.status
    delete admin_meeting_project_tracker_path(m.meeting_project_trackers.first)
    assert_not_equal 200, response.status
    assert_equal [@tracker.id], m.meeting_project_trackers.pluck(:project_tracker_id)
    assert_not m.reload.meeting_project_scan.human_locked?
  end
end
