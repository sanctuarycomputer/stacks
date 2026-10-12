require 'test_helper'

# The "Meeting Matches" page: which project tracker(s) the nightly sweep
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

  # A meeting as the sweep leaves it: its trackers (when it matched) in the
  # join, and a scan holding the model's confidence and reason.
  def matched!(title, tracker: @tracker, confidence: 0.9, rationale: "Title names the client.", started_at: 2.days.ago)
    m = meeting!(title, started_at: started_at)
    doc!(m)
    m.project_trackers << tracker if tracker
    MeetingScan.create!(meeting: m, outcome: tracker ? :linked : :no_match, scanned_at: 1.hour.ago,
                        confidence: confidence, rationale: rationale, scanned_hash: m.eligible_content_hash)
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

  def scan_of(meeting)
    MeetingScan.find_by!(meeting_id: meeting.id)
  end

  def row_for(meeting)
    page.at_css("#meeting_scan_#{scan_of(meeting).id}")
  end

  def linked_ids(meeting)
    meeting.project_trackers.reset.pluck(:id).sort
  end

  test "the index lists a matched meeting with its tracker, confidence and reason" do
    m = matched!("Harvey weekly sync")
    m.documents.first.update_columns(url: "https://docs.example/transcript-1")
    get admin_meeting_scans_path(scope: "all")
    assert_response :success
    row = row_for(m)
    assert_includes row.text, "Harvey weekly sync"
    assert_includes row.text, "Harvey Staff Augmentation"
    assert_includes row.text, "90%"
    assert_includes row.text, "Title names the client."
    assert_includes row.text, "Stacks (automatic)"
    assert_equal "_blank", row.at_css("a[href='https://docs.example/transcript-1']")["target"]
    assert row.at_css("a[href='#{admin_project_tracker_path(@tracker)}']")
    remove = row.at_css("a[href='#{remove_project_admin_meeting_scan_path(scan_of(m), project_tracker_id: @tracker.id)}']")
    assert_equal "delete", remove["data-method"]
    assert remove["data-confirm"].present?
    assert_equal "Add a project", row.at_css("a[href='#{add_project_admin_meeting_scan_path(scan_of(m))}']").text
    assert_includes page.css("#tabs, .header").text, "Meeting Matches"
  end

  test "the page is one resource: there is no second one for the links" do
    names = Rails.application.routes.named_routes.names.map(&:to_s)
    assert_includes names, "admin_meeting_scans"
    assert_includes names, "add_project_admin_meeting_scan"
    assert_includes names, "remove_project_admin_meeting_scan"
    assert_empty names.grep(/meeting_project/)
    assert_not_includes names, "admin_meeting_scan", "the page has an index only, no show"
  end

  test "Needs Review is the default and holds unmatched and unsure meetings only" do
    none = matched!("Studio standup", tracker: nil, confidence: 0.1)
    unsure = matched!("Maybe Harvey", confidence: 0.7)
    sure = matched!("Surely Harvey", confidence: 0.95)
    edge = matched!("Just sure enough", confidence: 0.8)
    locked = matched!("Corrected by a person", tracker: nil)
    scan_of(locked).update!(human_locked: true)
    locked_unsure = matched!("Unsure but settled by a person", confidence: 0.7)
    scan_of(locked_unsure).update!(human_locked: true)

    get admin_meeting_scans_path
    assert_response :success
    assert_includes response.body, "Studio standup"
    assert_includes response.body, "Maybe Harvey"
    assert_not_includes response.body, "Surely Harvey"
    assert_not_includes response.body, "Just sure enough"
    assert_not_includes response.body, "Corrected by a person"
    assert_not_includes response.body, "Unsure but settled by a person"

    get admin_meeting_scans_path(scope: "all")
    [none, unsure, sure, edge, locked, locked_unsure].each { |m| assert row_for(m), "expected #{m.title} under All" }
    assert_includes row_for(locked).text, "A person"

    get admin_meeting_scans_path(scope: "linked")
    assert_equal [unsure, sure].map { |m| row_for(m).present? }, [true, true]
    assert_nil row_for(none)

    get admin_meeting_scans_path(scope: "no_match")
    assert row_for(none)
    assert_nil row_for(sure)
  end

  test "a meeting older than the sweep's window appears only under All" do
    old = meeting!("Kickoff from last winter", started_at: 200.days.ago)
    doc!(old)
    MeetingScan.create!(meeting: old, outcome: :out_of_scope, scanned_at: 1.hour.ago, scanned_hash: old.eligible_content_hash)
    [nil, "needs_review", "linked", "no_match"].each do |scope|
      get admin_meeting_scans_path(scope: scope)
      assert_response :success
      assert_not_includes response.body, "Kickoff from last winter", "listed under #{scope.inspect}"
    end
    get admin_meeting_scans_path(scope: "all")
    assert_includes row_for(old).text, "Kickoff from last winter"
    assert_equal ["Needs Review", "Linked", "No Match", "All"], page.css(".scopes .table_tools_button").map { |a| a.text.gsub(/\s*\(\d+\)\s*/, "").strip }
  end

  test "meetings are listed newest first" do
    matched!("Older meeting", started_at: 5.days.ago)
    matched!("Newer meeting", started_at: 1.day.ago)
    matched!("Middle meeting", started_at: 3.days.ago)
    get admin_meeting_scans_path(scope: "all")
    body = response.body
    assert_operator body.index("Newer meeting"), :<, body.index("Middle meeting")
    assert_operator body.index("Middle meeting"), :<, body.index("Older meeting")
  end

  test "a meeting with no eligible document is listed nowhere and none of its text is shown" do
    private_tracker = tracker!("Zebra Confidential Engagement")
    m = matched!("PRIVATE-MEETING-TITLE", tracker: private_tracker, confidence: 0.7, rationale: "PRIVATE-RATIONALE about a salary.")
    exclude!(m.documents.first)
    unmatched = matched!("PRIVATE-MEETING-TITLE unmatched", tracker: nil, rationale: "PRIVATE-RATIONALE two.")
    exclude!(unmatched.documents.first)
    listed = matched!("Harvey weekly sync")
    ["needs_review", "linked", "no_match", "all", nil].each do |scope|
      get admin_meeting_scans_path(scope: scope)
      assert_response :success
      # Not just its text: the meeting has no row at all, under any scope.
      assert_nil row_for(m), "a private meeting has a row under #{scope.inspect}"
      assert_nil row_for(unmatched), "a private unmatched meeting has a row under #{scope.inspect}"
      assert_not_includes response.body, "Zebra Confidential Engagement"
      assert_not_includes response.body, add_project_admin_meeting_scan_path(scan_of(m))
      assert_not_includes response.body, "PRIVATE-MEETING-TITLE"
      assert_not_includes response.body, "PRIVATE-RATIONALE"
    end
    get admin_meeting_scans_path(scope: "all")
    assert_equal 1, page.css("tr[id^='meeting_scan_']").size
    assert row_for(listed)
  end

  test "an excluded notes document's title is never shown, though notes sort first" do
    m = meeting!("PRIVATE NOTES TITLE")
    exclude!(doc!(m, source: :gemini_notes, title: "PRIVATE NOTES TITLE", url: "https://docs.example/private-notes"))
    doc!(m, title: "Harvey weekly sync", url: "https://docs.example/transcript-2")
    MeetingScan.create!(meeting: m, outcome: :no_match, scanned_at: 1.hour.ago, scanned_hash: m.eligible_content_hash)

    get admin_meeting_scans_path(scope: "all")
    assert_includes row_for(m).text, "Harvey weekly sync"
    assert row_for(m).at_css("a[href='https://docs.example/transcript-2']")
    assert_not_includes response.body, "PRIVATE NOTES TITLE"
    assert_not_includes response.body, "https://docs.example/private-notes"
  end

  test "a reason written about an absorbed meeting's documents is not shown after the absorb" do
    survivor = matched!("Harvey weekly sync", tracker: nil, rationale: "Nothing names a client.")
    standalone = meeting!("Harvey weekly sync notes")
    notes = doc!(standalone, source: :gemini_notes)
    standalone.project_trackers << @tracker
    MeetingScan.create!(meeting: standalone, outcome: :linked, scanned_at: 1.hour.ago, confidence: 0.9,
                        rationale: "SECRET NOTES TEXT", scanned_hash: standalone.eligible_content_hash)
    # The notes are walled off, then the ETL folds the standalone meeting into the survivor.
    exclude!(notes)
    standalone.documents.update_all(source_record_id: survivor.id)
    survivor.absorb_project_matches_from!(standalone)
    standalone.reload.destroy

    get admin_meeting_scans_path(scope: "all")
    assert_response :success
    row = row_for(survivor.reload)
    assert_includes row.text, "Harvey Staff Augmentation", "the tracker itself came along"
    assert_not_includes response.body, "SECRET NOTES TEXT"
    assert_not_includes response.body, "Nothing names a client."
  end

  test "an absorbed scan that moved to a meeting with none never shows its old reason either" do
    survivor = meeting!("Harvey weekly sync")
    doc!(survivor)
    standalone = meeting!("Harvey weekly sync notes")
    notes = doc!(standalone, source: :gemini_notes)
    standalone.project_trackers << @tracker
    MeetingScan.create!(meeting: standalone, outcome: :linked, scanned_at: 1.hour.ago, confidence: 0.9,
                        rationale: "SECRET NOTES TEXT", scanned_hash: standalone.eligible_content_hash)
    exclude!(notes)
    standalone.documents.update_all(source_record_id: survivor.id)
    survivor.absorb_project_matches_from!(standalone)
    standalone.reload.destroy

    get admin_meeting_scans_path(scope: "all")
    assert_includes row_for(survivor).text, "Harvey Staff Augmentation"
    assert_not_includes response.body, "SECRET NOTES TEXT"
    assert_not_includes response.body, "90%"
  end

  test "the index issues the same number of queries for 2 meetings as for 6" do
    2.times { |i| matched!("Harvey sync #{i}") }
    get admin_meeting_scans_path(scope: "all") # warm up
    at_2 = count_queries { get admin_meeting_scans_path(scope: "all") }
    assert_equal 2, page.css("tr[id^='meeting_scan_']").size
    assert_includes response.body, "Title names the client."

    4.times { |i| matched!("Acme sync #{i}", tracker: tracker!("Acme #{i}")) }
    at_6 = count_queries { get admin_meeting_scans_path(scope: "all") }
    assert_equal 6, page.css("tr[id^='meeting_scan_']").size
    assert_equal at_2, at_6, "the page issues a query per row"
  end

  test "the title shown comes from an eligible document, never from the meeting row" do
    m = matched!("PRIVATE-TITLE the excluded transcript wrote", rationale: "r")
    exclude!(m.documents.first)
    doc!(m, source: :gemini_notes, title: "Harvey weekly sync")
    untitled = matched!("PRIVATE-TITLE two", tracker: nil, started_at: Time.zone.local(2026, 10, 9, 15))
    untitled.documents.first.update_columns(title: nil)

    get admin_meeting_scans_path(scope: "all")
    assert_includes row_for(m).text, "Harvey weekly sync"
    assert_includes row_for(untitled).text, "Meeting, October 9, 2026"
    assert_not_includes response.body, "PRIVATE-TITLE"
  end

  test "a reason does not outlive the text it was written from" do
    m = meeting!("Harvey weekly sync")
    transcript = doc!(m)
    doc!(m, source: :gemini_notes)
    m.project_trackers << @tracker
    MeetingScan.create!(meeting: m, outcome: :linked, scanned_at: 1.hour.ago, confidence: 0.9,
                        rationale: "QUOTES-THE-TRANSCRIPT", scanned_hash: m.eligible_content_hash)

    get admin_meeting_scans_path(scope: "all")
    assert_includes row_for(m).text, "QUOTES-THE-TRANSCRIPT"

    exclude!(transcript)
    get admin_meeting_scans_path(scope: "all")
    assert row_for(m), "the meeting is still listed: its notes are readable"
    assert_not_includes response.body, "QUOTES-THE-TRANSCRIPT"
  end

  test "the page has no CSV, JSON or XML form, which would hand out the hidden reason" do
    m = meeting!("Harvey weekly sync")
    transcript = doc!(m)
    doc!(m, source: :gemini_notes)
    m.project_trackers << @tracker
    MeetingScan.create!(meeting: m, outcome: :linked, scanned_at: 1.hour.ago, confidence: 0.9,
                        rationale: "QUOTES-THE-TRANSCRIPT", scanned_hash: m.eligible_content_hash)
    exclude!(transcript)

    %w[csv json xml].each do |format|
      begin
        get admin_meeting_scans_path(scope: "all", format: format)
      rescue ActionController::UnknownFormat, ActionController::RoutingError
        next
      end
      assert_not_equal 200, response.status, "#{format} should not be served"
      assert_not_includes response.body, "QUOTES-THE-TRANSCRIPT"
    end
  end

  test "search and sort parameters are ignored, so they cannot probe excluded text" do
    hit = meeting!("Harvey weekly sync")
    doc!(hit)
    hit.segments.create!(position: 0, text: "the secret phrase zebra-crossing", speaker_name: "Sam Lead")
    hit.project_trackers << @tracker
    MeetingScan.create!(meeting: hit, outcome: :linked, scanned_at: 1.hour.ago, confidence: 0.9,
                        rationale: "zebra-reason", scanned_hash: hit.eligible_content_hash)
    miss = matched!("Acme weekly sync", rationale: "Other reason.")

    [{ "meeting_segments_text_cont" => "zebra-crossing" }, { "rationale_cont" => "zebra-reason" },
     { "meeting_title_cont" => "Harvey" }].each do |q|
      get admin_meeting_scans_path(scope: "all", q: q)
      assert_response :success
      assert row_for(hit), "#{q.keys.first} must not filter"
      assert row_for(miss), "#{q.keys.first} must not filter: a miss would tell the searcher something"
    end

    get admin_meeting_scans_path(scope: "all", order: "rationale_desc")
    assert_response :success
    asc = page.css("tr[id^='meeting_scan_']").map { |tr| tr["id"] }
    get admin_meeting_scans_path(scope: "all", order: "rationale_asc")
    assert_equal asc, page.css("tr[id^='meeting_scan_']").map { |tr| tr["id"] }, "the order does not follow the request"
  end

  test "a model-written reason is escaped" do
    matched!("Harvey weekly sync", rationale: "<script>alert('x')</script> names the client")
    get admin_meeting_scans_path(scope: "all")
    assert_not_includes response.body, "<script>alert('x')"
    assert_includes response.body, "&lt;script&gt;alert("
  end

  test "the add-a-project form names the meeting and offers trackers still in flight, by name" do
    m = matched!("Studio standup", tracker: nil)
    tracker!("Acme Phase 2")
    done = ProjectTracker.new(name: "Finished Project", work_completed_at: 1.month.ago).tap { |t| t.save!(validate: false) }
    get add_project_admin_meeting_scan_path(scan_of(m))
    assert_response :success
    form = page.at_css("form[action='#{add_project_admin_meeting_scan_path(scan_of(m))}']")
    assert_equal "post", form["method"]
    assert_includes form.text, "Studio standup"
    options = form.css("select[name='project_tracker_id'] option").map(&:text).reject(&:blank?)
    assert_equal ["Acme Phase 2", "Harvey Staff Augmentation"], options
    assert_not_includes options, done.name
    assert form.at_css("a[href='#{admin_meeting_scans_path}']"), "Cancel goes back to Meeting Matches"
    assert_includes page.css("#tabs, .header").text, "Meeting Matches", "the form sits in the admin layout"
  end

  test "the add-a-project form takes the meeting's title from an eligible document, never from the meeting row" do
    m = matched!("Harvey weekly sync", tracker: nil)
    m.update_columns(title: "PRIVATE ROW TITLE")
    get add_project_admin_meeting_scan_path(scan_of(m))
    assert_response :success
    assert_includes page.css("form").text, "Harvey weekly sync"
    assert_not_includes response.body, "PRIVATE ROW TITLE"
  end

  test "the form escapes a title" do
    m = matched!("<script>alert('t')</script> sync", tracker: nil)
    get add_project_admin_meeting_scan_path(scan_of(m))
    assert_not_includes response.body, "<script>alert('t')"
  end

  test "adding a project links it, locks the scan and returns to the page" do
    m = matched!("Studio standup", tracker: nil)
    post add_project_admin_meeting_scan_path(scan_of(m)), params: { project_tracker_id: @tracker.id }
    assert_redirected_to admin_meeting_scans_path
    assert_equal [@tracker.id], linked_ids(m)
    scan = scan_of(m)
    assert scan.human_locked?
    assert scan.linked?
    follow_redirect!
    assert_includes response.body, "Harvey Staff Augmentation was added"
  end

  test "adding with no project chosen, or one that does not exist, changes nothing" do
    m = matched!("Studio standup", tracker: nil)
    [{}, { project_tracker_id: "" }, { project_tracker_id: 0 }].each do |params|
      post add_project_admin_meeting_scan_path(scan_of(m)), params: params
      assert_redirected_to add_project_admin_meeting_scan_path(scan_of(m))
      assert_equal [], linked_ids(m)
      assert_not scan_of(m).human_locked?
    end
  end

  test "removing a project locks the scan as no_match and returns to the page" do
    m = matched!("Harvey weekly sync")
    delete remove_project_admin_meeting_scan_path(scan_of(m), project_tracker_id: @tracker.id)
    assert_redirected_to admin_meeting_scans_path
    assert_equal [], linked_ids(m)
    scan = scan_of(m)
    assert scan.human_locked?
    assert scan.no_match?
    assert ProjectTracker.exists?(@tracker.id), "only the link went"
  end

  test "removing one of two projects leaves the scan linked" do
    m = matched!("Harvey weekly sync")
    other = tracker!("Acme Phase 2")
    m.project_trackers << other
    delete remove_project_admin_meeting_scan_path(scan_of(m), project_tracker_id: other.id)
    assert_equal [@tracker.id], linked_ids(m)
    assert scan_of(m).linked?
    assert scan_of(m).human_locked?
  end

  test "neither action shows or changes a meeting the corpus cannot read" do
    m = matched!("PRIVATE-MEETING-TITLE")
    exclude!(m.documents.first)
    scan = scan_of(m)

    get add_project_admin_meeting_scan_path(scan)
    assert_redirected_to admin_meeting_scans_path
    assert_not_includes response.body, "PRIVATE-MEETING-TITLE"
    follow_redirect!
    assert_not_includes response.body, "PRIVATE-MEETING-TITLE"
    assert_includes page.css(".flash").text, "no document in Stacks search"

    other = tracker!("Acme Phase 2")
    post add_project_admin_meeting_scan_path(scan), params: { project_tracker_id: other.id }
    assert_redirected_to admin_meeting_scans_path
    assert_not_includes response.body, "PRIVATE-MEETING-TITLE"
    delete remove_project_admin_meeting_scan_path(scan, project_tracker_id: @tracker.id)
    assert_redirected_to admin_meeting_scans_path
    assert_not_includes response.body, "PRIVATE-MEETING-TITLE"

    assert_equal [@tracker.id], linked_ids(m)
    assert_not scan.reload.human_locked?
    assert scan.linked?
  end

  test "a meeting that stops being readable between the check and the write is refused, not an error" do
    m = matched!("Studio standup", tracker: nil)
    Meeting.any_instance.stubs(:link_project!).raises(ActiveRecord::RecordInvalid.new(m))
    post add_project_admin_meeting_scan_path(scan_of(m)), params: { project_tracker_id: @tracker.id }
    assert_redirected_to admin_meeting_scans_path
    assert_match(/no document in Stacks search/, flash[:alert])
  end

  test "an action on a scan that does not exist goes back to the page" do
    get "/admin/meeting_scans/0/add_project"
    assert_redirected_to admin_meeting_scans_path
    post "/admin/meeting_scans/0/add_project", params: { project_tracker_id: @tracker.id }
    assert_redirected_to admin_meeting_scans_path
    delete "/admin/meeting_scans/0/remove_project", params: { project_tracker_id: @tracker.id }
    assert_redirected_to admin_meeting_scans_path
  end

  test "a lead can open the page and add and remove a project" do
    lead = AdminUser.create!(email: "lead#{SecureRandom.hex(4)}@sanctuary.computer",
                             password: 'password12345', password_confirmation: 'password12345')
    PermissionGrant.create!(admin_user: lead, permission: "lead", granted_by: @admin)
    m = matched!("Harvey weekly sync")
    other = tracker!("Acme Phase 2")
    sign_out @admin
    sign_in lead
    get admin_meeting_scans_path(scope: "all")
    assert_response :success
    assert_includes response.body, "Harvey weekly sync"

    get add_project_admin_meeting_scan_path(scan_of(m))
    assert_response :success
    post add_project_admin_meeting_scan_path(scan_of(m)), params: { project_tracker_id: other.id }
    assert_redirected_to admin_meeting_scans_path
    assert_equal [@tracker.id, other.id].sort, linked_ids(m)
    delete remove_project_admin_meeting_scan_path(scan_of(m), project_tracker_id: other.id)
    assert_redirected_to admin_meeting_scans_path
    assert_equal [@tracker.id], linked_ids(m)
  end

  test "a project-scoped lead grantee can neither open the page nor change a match" do
    trainee = AdminUser.create!(email: "trainee#{SecureRandom.hex(4)}@sanctuary.computer",
                                password: 'password12345', password_confirmation: 'password12345')
    PermissionGrant.create!(admin_user: trainee, permission: "lead", subject: @tracker, granted_by: @admin)
    m = matched!("Harvey weekly sync")
    other = tracker!("Acme Phase 2")
    scan = scan_of(m)
    sign_out @admin
    sign_in trainee

    get admin_meeting_scans_path(scope: "all")
    assert_not_equal 200, response.status
    assert_not_includes response.body, "Harvey weekly sync"

    get add_project_admin_meeting_scan_path(scan)
    assert_not_equal 200, response.status
    assert_not_includes response.body, "Harvey weekly sync"
    assert_not_includes response.body, "Acme Phase 2"

    post add_project_admin_meeting_scan_path(scan), params: { project_tracker_id: other.id }
    assert_not_equal 200, response.status
    assert_equal [@tracker.id], linked_ids(m)

    delete remove_project_admin_meeting_scan_path(scan, project_tracker_id: @tracker.id)
    assert_not_equal 200, response.status
    assert_equal [@tracker.id], linked_ids(m)
    assert_not scan.reload.human_locked?
    assert scan.linked?
  end

  test "the grantee is refused the same way for a meeting the corpus cannot read, and for a missing scan" do
    trainee = AdminUser.create!(email: "trainee#{SecureRandom.hex(4)}@sanctuary.computer",
                                password: 'password12345', password_confirmation: 'password12345')
    PermissionGrant.create!(admin_user: trainee, permission: "lead", subject: @tracker, granted_by: @admin)
    m = matched!("PRIVATE-MEETING-TITLE")
    exclude!(m.documents.first)
    sign_out @admin
    sign_in trainee
    delete remove_project_admin_meeting_scan_path(scan_of(m), project_tracker_id: @tracker.id)
    assert_not_equal 200, response.status
    assert_equal [@tracker.id], linked_ids(m)
    assert_no_match(/no document in Stacks search/, flash.to_h.values.join, "the refusal says nothing about the meeting")
    get "/admin/meeting_scans/0/add_project"
    assert_not_equal 200, response.status
    assert_no_match(/no document in Stacks search/, flash.to_h.values.join)
  end
end
