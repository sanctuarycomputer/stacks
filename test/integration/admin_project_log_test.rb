require 'test_helper'

# The project log: what Stacksbot filed under a tracker's Notion projects,
# read from notion_pages. Nothing here reaches Notion.
class AdminProjectLogTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include NotionLogFixtures

  setup do
    System.delete_all
    System.create!(settings: { "notion_filtered_sync_marks" => { "OBSERVATIONS" => 2.hours.ago.utc.iso8601 } })
    @admin = AdminUser.create!(email: "logadmin#{SecureRandom.hex(4)}@sanctuary.computer",
                               password: 'password12345', password_confirmation: 'password12345', roles: ['admin'])
    sign_in @admin
    @tracker, @project = log_tracker!(name: "Harvey Build")
  end

  def obs!(**attrs)
    observation!(**{ project_ids: [@project], observed_at: 1.day.ago }.merge(attrs))
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def row_for(notion_page)
    page.at_css("#log_row_#{notion_page.notion_id}")
  end

  def module_titled(title)
    page.css(".dashboard-module").find { |m| m.at_css(".module-header p")&.text&.strip == title }
  end

  def scoped_grantee!(tracker = @tracker)
    trainee = AdminUser.create!(email: "trainee#{SecureRandom.hex(4)}@sanctuary.computer",
                                password: 'password12345', password_confirmation: 'password12345')
    PermissionGrant.create!(admin_user: trainee, permission: "lead", subject: tracker, granted_by: @admin)
    trainee
  end

  test "the default view is Needs attention: open problems, then negative rows with the escalated ones red" do
    problem = problem!(name: "Timeline slipping", severity: "Critical", status: "Open", owner: nil,
                       occurrences: 4, project_ids: [@project])
    escalated = obs!(name: "Client asked twice for a date", text: "No answer in the channel.", valence: "Negative",
                     salience: "High", source: "Twist", problem_ids: [problem.notion_id])
    plain = obs!(name: "Design review ran long", valence: "Negative", salience: "Low", observed_at: 2.hours.ago)
    win = obs!(name: "Launch praised", valence: "Positive")

    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_equal "Needs attention", page.at_css(".log-tab.current")&.text&.strip
    problems = module_titled("Open problems")
    assert problems, "expected the Open problems module"
    assert_includes problems.text, "Timeline slipping"
    assert_includes problems.text, "Critical"
    assert_includes problems.text, "Nobody owns it yet"
    assert_includes problems.text, "Seen 4 times"

    ids = page.css("tr[id^='log_row_']").map { |tr| tr["id"] }
    assert_equal ["log_row_#{escalated.notion_id}", "log_row_#{plain.notion_id}"], ids, "escalated first; the win is not here"
    assert_equal "pill error", row_for(escalated).at_css(".pill")["class"]
    assert_equal "Escalated", row_for(escalated).at_css(".pill").text.strip
    assert_equal "pill at_risk", row_for(plain).at_css(".pill")["class"]
    assert_includes row_for(escalated).text, "No answer in the channel."
    assert_includes row_for(escalated).text, "Twist"
    assert_includes row_for(escalated).text, "Folded into"
    assert_includes row_for(escalated).text, "Timeline slipping"
    assert_equal "https://twist.com/a/133876/ch/1/t/2/", row_for(escalated).at_css("a.log-source")["href"]
    assert_nil row_for(win)
  end

  test "Highlights groups gated rows by week and Everything shows dismissed and unmarked rows too" do
    this_week = obs!(name: "Launch praised", valence: "Positive", observed_at: Time.zone.now.beginning_of_week + 1.hour)
    last_week = obs!(name: "Scope agreed", valence: "Neutral", observed_at: Time.zone.now.beginning_of_week - 2.days)
    dismissed = obs!(name: "False alarm", valence: "Negative", status: "Dismissed")
    unmarked = obs!(name: "Routine note", valence: nil, type: "FYI")

    get admin_project_tracker_log_path(@tracker, view: "highlights")
    assert_response :success
    assert_equal 2, page.css(".log-week").size
    assert_match(/\AWeek of /, page.css(".log-week").first.text.strip)
    assert row_for(this_week)
    assert row_for(last_week)
    assert_nil row_for(dismissed)
    assert_nil row_for(unmarked)
    assert_equal "pill exceptional", row_for(this_week).at_css(".pill")["class"]
    assert_match(/background-color/, row_for(last_week).at_css(".pill")["style"], "neutral is grey")

    get admin_project_tracker_log_path(@tracker, view: "everything")
    [this_week, last_week, dismissed, unmarked].each { |r| assert row_for(r), "#{r.page_title} is under Everything" }
    assert_includes row_for(dismissed).text, "Dismissed"
    assert_equal "Not marked", row_for(unmarked).at_css(".pill").text.strip
  end

  test "chips filter, combine with a view, and keep the view in their links" do
    twist = obs!(name: "From Twist", source: "Twist", valence: "Negative")
    meet = obs!(name: "From a meeting", source: "Google Meet", valence: "Negative")
    get admin_project_tracker_log_path(@tracker, view: "everything", source: "meet")
    assert_response :success
    assert row_for(meet)
    assert_nil row_for(twist)
    chip = page.css("a.log-chip").find { |a| a.text.strip == "Twist" }
    assert_equal admin_project_tracker_log_path(@tracker, view: "everything", source: "twist"), chip["href"]
    assert_equal "Meet", page.at_css("a.log-chip.current").text.strip
    tab = page.css("a.log-tab").find { |a| a.text.strip == "Highlights" }
    assert_equal admin_project_tracker_log_path(@tracker, view: "highlights", source: "meet"), tab["href"]

    get admin_project_tracker_log_path(@tracker, view: "everything", source: "meet", valence: "positive")
    assert_nil row_for(meet)
    assert_includes response.body, "No rows match these filters"
  end

  test "parameters outside the whitelist are ignored, never an error and never echoed" do
    row = obs!(name: "Something negative", valence: "Negative")
    get admin_project_tracker_log_path(@tracker), params: {
      view: "<script>x</script>", source: ["twist"], valence: { a: 1 }, page: "-4",
      q: { "page_title_cont" => "zzz" }, order: "page_title_desc", scope: "all"
    }
    assert_response :success
    assert row_for(row), "an unknown view is Needs attention, and q and order do nothing"
    assert_not_includes response.body, "<script>x</script>"
  end

  test "the page has no CSV, JSON or XML form" do
    obs!(name: "QUOTED-FROM-A-CHANNEL", valence: "Negative")
    %w[csv json xml].each do |format|
      begin
        get admin_project_tracker_log_path(@tracker, format: format)
      rescue ActionController::UnknownFormat, ActionController::RoutingError
        next
      end
      assert_not_equal 200, response.status, "#{format} should not be served"
      assert_not_includes response.body, "QUOTED-FROM-A-CHANNEL"
    end
  end

  test "model-written text is escaped and only a web address is linked" do
    row = obs!(name: "<script>alert('n')</script> name", text: "<img src=x onerror=alert(1)> text",
               source_ref: "javascript:alert(1)", valence: "Negative")
    problem!(name: "<b>bold problem</b>", project_ids: [@project])
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_not_includes response.body, "<script>alert('n')"
    assert_not_includes response.body, "<img src=x"
    assert_not_includes response.body, "<b>bold problem</b>"
    assert_includes row_for(row).text, "<script>alert('n')</script> name"
    assert_nil row_for(row).at_css("a.log-source"), "a javascript: address is not a link"
    assert_empty page.css("a[href^='javascript']")
  end

  test "before Valence exists the page shows risks as negative and says the rule is interim" do
    risk = obs!(name: "Budget at risk", valence: nil, valence_property: false, type: "Risk")
    obs!(name: "Plain note", valence: nil, valence_property: false, type: "FYI")
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_equal "pill at_risk", row_for(risk).at_css(".pill")["class"]
    assert_includes response.body, "Stacksbot has not marked these rows yet"
    get admin_project_tracker_log_path(@tracker, view: "everything")
    assert_equal 2, page.css("tr[id^='log_row_']").size
  end

  test "no Notion project chosen: says so and links to the tracker's edit form" do
    bare, = log_tracker!(name: "Unlinked", project: nil)
    get admin_project_tracker_log_path(bare)
    assert_response :success
    assert_includes response.body, "no Notion project chosen"
    assert page.at_css("a[href='#{edit_admin_project_tracker_path(bare)}']")
    assert_empty page.css(".log-tab"), "no tabs over an empty log"
  end

  test "nothing synced yet: says the sync has not run" do
    System.first.update!(notion_filtered_sync_marks: {})
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_includes response.body, "has not synced Stacksbot's observations yet"
  end

  test "nothing seen: says so, and names a missing or unreadable Twist channel" do
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_includes response.body, "has not filed anything under this project yet"
    assert_includes response.body, "no Twist channel linked"

    @tracker.update_columns(twist_channels_inaccessible: [355509])
    ProjectTracker.any_instance.stubs(:twist_channel_ids).returns([355509])
    get admin_project_tracker_log_path(@tracker)
    assert_includes response.body, "Stacksbot is not in 1 of this project's Twist channels"
  end

  test "rows exist but none needs attention: says so and points at Everything" do
    obs!(name: "Routine note", valence: nil, type: "FYI")
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_includes response.body, "Nothing needs attention"
    assert page.at_css("a[href='#{admin_project_tracker_log_path(@tracker, view: "everything")}']")
  end

  test "Everything is paged" do
    Stacks::ProjectLog.stub_const(:PER_PAGE, 2) do
      rows = Array.new(3) { |i| obs!(name: "Row #{i}", valence: nil, type: "FYI", observed_at: (i + 1).hours.ago) }
      get admin_project_tracker_log_path(@tracker, view: "everything")
      assert_equal 2, page.css("tr[id^='log_row_']").size
      older = page.at_css("a.log-older")
      assert_equal admin_project_tracker_log_path(@tracker, view: "everything", page: 2), older["href"]
      assert_nil page.at_css("a.log-newer")
      get older["href"]
      assert_equal ["log_row_#{rows.last.notion_id}"], page.css("tr[id^='log_row_']").map { |tr| tr["id"] }
      assert page.at_css("a.log-newer")
      assert_nil page.at_css("a.log-older")
    end
  end

  test "a row with broken stored data is drawn, not a 500" do
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Notion.filtered_parent_id(:OBSERVATIONS),
                       data: { "properties" => [] }, project_ids: [@project], occurred_at: 1.day.ago)
    get admin_project_tracker_log_path(@tracker, view: "everything")
    assert_response :success
    assert_includes response.body, "Untitled"
    assert_includes response.body, "Unknown source"
  end

  test "a lead can open the log" do
    lead = AdminUser.create!(email: "lead#{SecureRandom.hex(4)}@sanctuary.computer",
                             password: 'password12345', password_confirmation: 'password12345')
    PermissionGrant.create!(admin_user: lead, permission: "lead", granted_by: @admin)
    obs!(name: "Client unhappy", valence: "Negative")
    sign_out @admin
    sign_in lead
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_includes response.body, "Client unhappy"
  end

  test "a project-scoped lead grantee can open the log of their tracker and no other" do
    other, other_project = log_tracker!(name: "Acme Phase 2")
    obs!(name: "Mine to read", valence: "Negative")
    observation!(name: "NOT-MINE-TO-READ", valence: "Negative", project_ids: [other_project], observed_at: 1.day.ago)
    trainee = scoped_grantee!
    sign_out @admin
    sign_in trainee

    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_includes response.body, "Mine to read"
    assert_not_includes response.body, "NOT-MINE-TO-READ"

    get admin_project_tracker_log_path(other)
    assert_not_equal 200, response.status
    assert_not_includes response.body, "NOT-MINE-TO-READ"
    assert_not_includes response.body, "Acme Phase 2"
  end

  test "a scoped grantee gets no edit link in an empty state" do
    bare, = log_tracker!(name: "Unlinked", project: nil)
    trainee = scoped_grantee!(bare)
    sign_out @admin
    sign_in trainee
    get admin_project_tracker_log_path(bare)
    assert_response :success
    assert_includes response.body, "no Notion project chosen"
    assert_nil page.at_css("a[href='#{edit_admin_project_tracker_path(bare)}']")
  end

  test "someone with no access to trackers cannot open a log" do
    nobody = AdminUser.create!(email: "nobody#{SecureRandom.hex(4)}@sanctuary.computer",
                               password: 'password12345', password_confirmation: 'password12345')
    obs!(name: "NOT-FOR-EVERYONE", valence: "Negative")
    sign_out @admin
    sign_in nobody
    get admin_project_tracker_log_path(@tracker)
    assert_not_equal 200, response.status
    assert_not_includes response.body, "NOT-FOR-EVERYONE"
  end

  test "a signed-out visitor is sent to sign in" do
    sign_out @admin
    get admin_project_tracker_log_path(@tracker)
    assert_response :redirect
  end
end
