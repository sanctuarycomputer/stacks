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

  def flag_for(notion_page)
    page.at_css("#log_flag_#{notion_page.notion_id}")
  end

  def section(id)
    page.at_css("##{id}")
  end

  def header_of(node)
    node.css(".module-header p").map { |p| p.text.strip }
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

  test "one page, top to bottom: Flags, Other open problems, Wins, All Observations" do
    problem = problem!(name: "Timeline slipping", severity: "Critical", status: "Open", occurrences: 4,
                       last_seen: 4.days.ago,
                       flag: "Critical severity problem. Nobody owns it yet.", proposed_action: "Ask Sam to confirm the date.",
                       project_ids: [@project])
    evidence = obs!(name: "Client asked twice for a date", text: "No answer in the channel.", valence: "Negative",
                    salience: "High", type: "Risk", source: "Twist", flag: "High-salience risk.", problem_ids: [problem.notion_id])
    lone = obs!(name: "Invoice disputed", valence: "Negative", salience: "High", type: "Risk", source: "Gmail",
                flag: "High-salience risk.", observed_at: 2.hours.ago)
    owned = problem!(name: "Scope creep", severity: "High", status: "Owned", owner: "Sam Lead", flag: "", project_ids: [@project])
    plain = obs!(name: "Design review ran long", valence: "Negative", salience: "Low", flag: "", observed_at: 3.hours.ago)
    win = obs!(name: "Launch praised", valence: "Positive", flag: "")

    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    doc = page
    ids = %w[flags other-open-problems wins all-observations]
    assert_equal ids, doc.css(ids.map { |id| "##{id}" }.join(", ")).map { |n| n["id"] }, "in this order down the page"
    assert_empty page.css(".log-tab"), "no view tabs"

    assert_equal %w[Flags 2], header_of(section("flags"))
    assert_includes section("flags").at_css(".log-flag-rule").text.squish,
                    "A flag clears when its problem is resolved or picked up in Notion, or when it has not come up for 30 days."
    assert_equal ["log_flag_#{problem.notion_id}", "log_flag_#{lone.notion_id}"], section("flags").css("tr.log-flag").map { |tr| tr["id"] }
    section("flags").css("tr.log-flag").each do |tr|
      assert_equal ["pill error", "Flag"], [tr.at_css(".pill")["class"], tr.at_css(".pill").text.strip]
    end
    flag = flag_for(problem)
    assert_includes flag.text, "Timeline slipping"
    assert_match(/\ACritical severity problem\. Nobody owns it yet\. Seen 4 times, last on \w+ \d+, \d{4}\.\z/, flag.at_css(".log-flag-why").text.strip)
    assert_equal "Next step: Ask Sam to confirm the date.", flag.at_css(".log-flag-next").text.squish
    nested = flag.at_css("#log_evidence_#{evidence.notion_id}")
    assert nested, "the tied observation is nested under its flag"
    assert_includes nested.text, "Client asked twice for a date"
    assert_includes nested.text, "Twist"
    assert_equal "https://twist.com/a/133876/ch/1/t/2/", nested.at_css("a.log-source")["href"]
    assert nested.css("a").any? { |a| a.text.strip == "Notion ↗" }
    assert flag.css("a").any? { |a| a.text.strip == "In Notion ↗" && a["href"] == problem.as_problem.notion_url }
    assert_nil flag_for(evidence), "and is not a flag of its own"
    assert_match(/\AHigh-salience risk\. Seen in Gmail on /, flag_for(lone).at_css(".log-flag-why").text.strip)
    assert_equal "Next step: Read the source. If it is a real problem, raise it; otherwise dismiss it in Notion.",
                 flag_for(lone).at_css(".log-flag-next").text.squish
    assert_nil section("flags").at_css(".log-flag-interim"), "every row carries Notion's Flag"

    others = section("other-open-problems")
    assert_equal ["Other open problems", "1"], header_of(others)
    listed = others.at_css("#log_problem_#{owned.notion_id}")
    assert_includes listed.text.squish, "Severity: High · Owned by Sam Lead"
    assert_empty listed.css(".pill"), "no bare coloured severity pill"

    assert_equal %w[Wins 1], header_of(section("wins"))
    assert section("wins").at_css("#log_win_#{win.notion_id}")
    assert_equal "pill exceptional", section("wins").at_css("#log_win_#{win.notion_id} .pill")["class"]

    all = section("all-observations")
    assert_equal ["All Observations", "4"], header_of(all)
    assert_equal [win, lone, plain, evidence].map { |r| "log_row_#{r.notion_id}" }.sort, all.css("tr[id^='log_row_']").map { |tr| tr["id"] }.sort
    assert_equal ["Negative", "Flag"], row_for(evidence).css(".pill").map { |n| n.text.strip }, "valence, and that it is part of a flag"
    assert_equal ["Negative", "Flag"], row_for(lone).css(".pill").map { |n| n.text.strip }
    assert_equal ["Negative"], row_for(plain).css(".pill").map { |n| n.text.strip }
    assert_equal "pill at_risk", row_for(plain).at_css(".pill")["class"]
    assert_includes row_for(evidence).text, "No answer in the channel."
    assert_includes row_for(evidence).text, "Folded into"

    assert_no_match(/escalat/i, doc.text)
  end

  test "an old link with ?view= still loads the same page" do
    risk = obs!(name: "Invoice disputed", valence: "Negative", salience: "High")
    %w[attention highlights everything nonsense].each do |view|
      get admin_project_tracker_log_path(@tracker, view: view)
      assert_response :success, view
      assert flag_for(risk), view
      assert row_for(risk), view
      assert_equal %w[flags wins all-observations], page.css("#flags, #other-open-problems, #wins, #all-observations").map { |n| n["id"] }
    end
  end

  test "rows synced before Notion had Flag use the interim rule, and the page says so once" do
    problem = problem!(name: "Timeline slipping", severity: "High", status: "Open", occurrences: 1, project_ids: [@project])
    taken = problem!(name: "Scope creep", severity: "Critical", status: "Mitigating", owner: "Ada", project_ids: [@project])
    quiet = problem!(name: "Old worry", severity: "High", status: "Open", last_seen: 45.days.ago, project_ids: [@project])
    risk = obs!(name: "Invoice disputed", valence: "Negative", salience: "High", source: "Twist")
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_equal 1, page.css(".log-flag-interim").size
    assert_match(/\AHigh severity problem\. Nobody owns it yet\. Last seen on /, flag_for(problem).at_css(".log-flag-why").text.strip)
    assert_equal "Next step: Pick it up or resolve it in Notion.", flag_for(problem).at_css(".log-flag-next").text.squish
    assert_match(/\AHigh-salience negative observation\. Seen in Twist on /, flag_for(risk).at_css(".log-flag-why").text.strip)
    assert_equal "Not a flag: Ada is mitigating it.", page.at_css("#log_problem_#{taken.notion_id} .log-not-a-flag").text.strip
    assert_includes page.at_css("#log_problem_#{taken.notion_id}").text.squish, "Severity: Critical · Being mitigated by Ada"
    assert_equal "Not a flag: not seen for 30 days.", page.at_css("#log_problem_#{quiet.notion_id} .log-not-a-flag").text.strip
  end

  test "no flags: says so, and the rest of the page is still there" do
    win = obs!(name: "Launch praised", valence: "Positive")
    obs!(name: "Routine note", valence: nil, type: "FYI")
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    assert_equal %w[Flags 0], header_of(section("flags"))
    assert_includes section("flags").text.squish,
                    "No flags. Nothing high-severity is open and unowned, and nothing high-salience and negative has come up in the last 30 days."
    assert_nil section("other-open-problems"), "the section is left out when there are none"
    assert section("wins").at_css("#log_win_#{win.notion_id}")
    assert_equal 2, section("all-observations").css("tr[id^='log_row_']").size
  end

  test "wins: capped, with the full count and a way to all of them" do
    Stacks::ProjectLog.stub_const(:WINS_LIMIT, 2) do
      3.times { |i| obs!(name: "Win #{i}", valence: "Positive", observed_at: (i + 1).hours.ago) }
      get admin_project_tracker_log_path(@tracker)
      assert_equal %w[Wins 3], header_of(section("wins"))
      assert_equal 2, section("wins").css("tr[id^='log_win_']").size
      assert_equal admin_project_tracker_log_path(@tracker, valence: "positive", anchor: "all-observations"),
                   section("wins").at_css("a.log-all-wins")["href"]
    end
    Stacks::ProjectLog.stub_const(:WINS_LIMIT, 20) do
      get admin_project_tracker_log_path(@tracker)
      assert_nil section("wins").at_css("a.log-all-wins")
    end
  end

  test "no wins: one line" do
    obs!(name: "Routine note", valence: nil, type: "FYI")
    get admin_project_tracker_log_path(@tracker)
    assert_includes section("wins").text.squish, "No wins in the last 30 days."
  end

  test "All Observations shows dismissed and unmarked rows too, each with its valence pill" do
    positive = obs!(name: "Launch praised", valence: "Positive", observed_at: 40.days.ago)
    neutral = obs!(name: "Scope agreed", valence: "Neutral")
    dismissed = obs!(name: "False alarm", valence: "Negative", salience: "High", status: "Dismissed")
    unmarked = obs!(name: "Routine note", valence: nil, type: "FYI")
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    [positive, neutral, dismissed, unmarked].each { |r| assert row_for(r), "#{r.page_title} is under All Observations" }
    assert_equal "pill exceptional", row_for(positive).at_css(".pill")["class"]
    assert_match(/background-color/, row_for(neutral).at_css(".pill")["style"], "neutral is grey")
    assert_includes row_for(dismissed).text, "Dismissed"
    assert_equal ["Negative"], row_for(dismissed).css(".pill").map { |n| n.text.strip }, "a dismissed row is no flag"
    assert_equal "Not marked", row_for(unmarked).at_css(".pill").text.strip
    assert_nil flag_for(dismissed)
  end

  test "the filters apply to All Observations only, and their links land on it" do
    twist = obs!(name: "From Twist", source: "Twist", valence: "Negative", salience: "High")
    meet = obs!(name: "From a meeting", source: "Google Meet", valence: "Negative")
    win = obs!(name: "A win in Twist", source: "Twist", valence: "Positive")
    get admin_project_tracker_log_path(@tracker, source: "meet")
    assert_response :success
    assert row_for(meet)
    assert_nil row_for(twist)
    assert flag_for(twist), "the flags do not move with the filter"
    assert section("wins").at_css("#log_win_#{win.notion_id}"), "nor do the wins"
    chip = page.css("a.log-chip").find { |a| a.text.strip == "Twist" }
    assert_equal admin_project_tracker_log_path(@tracker, source: "twist", anchor: "all-observations"), chip["href"]
    assert_equal "Meet", page.at_css("a.log-chip.current").text.strip
    negative = page.css("a.log-chip").find { |a| a.text.strip == "Negative" }
    assert_equal admin_project_tracker_log_path(@tracker, source: "meet", valence: "negative", anchor: "all-observations"), negative["href"]
    assert page.css("a.log-chip").none? { |a| a["href"].include?("view=") }

    get admin_project_tracker_log_path(@tracker, source: "meet", valence: "positive")
    assert_nil row_for(meet)
    assert_includes response.body, "No observations match these filters"
  end

  test "parameters outside the whitelist are ignored, never an error and never echoed" do
    row = obs!(name: "Something negative", valence: "Negative")
    get admin_project_tracker_log_path(@tracker), params: {
      view: "<script>x</script>", source: ["twist"], valence: { a: 1 }, page: "-4",
      q: { "page_title_cont" => "zzz" }, order: "page_title_desc", scope: "all"
    }
    assert_response :success
    assert row_for(row), "an unknown view is ignored, and q and order do nothing"
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
    assert_equal 1, section("all-observations").css(".log-valence-interim").size
    assert_includes response.body, "Stacksbot has not marked these rows yet"
    assert_equal 2, page.css("tr[id^='log_row_']").size
  end

  test "no Notion project chosen: says so and links to the tracker's edit form" do
    bare, = log_tracker!(name: "Unlinked", project: nil)
    get admin_project_tracker_log_path(bare)
    assert_response :success
    assert_includes response.body, "no Notion project chosen"
    assert page.at_css("a[href='#{edit_admin_project_tracker_path(bare)}']")
    assert_empty page.css("#flags, #wins, #all-observations"), "no sections over an empty log"
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



  test "All Observations is paged, and the page links land on it" do
    Stacks::ProjectLog.stub_const(:PER_PAGE, 2) do
      rows = Array.new(3) { |i| obs!(name: "Row #{i}", valence: nil, type: "FYI", observed_at: (i + 1).hours.ago) }
      get admin_project_tracker_log_path(@tracker)
      assert_equal 2, page.css("tr[id^='log_row_']").size
      assert_equal ["All Observations", "2+"], header_of(section("all-observations"))
      older = page.at_css("a.log-older")
      assert_equal admin_project_tracker_log_path(@tracker, page: 2, anchor: "all-observations"), older["href"]
      assert_nil page.at_css("a.log-newer")
      get older["href"]
      assert_equal ["log_row_#{rows.last.notion_id}"], page.css("tr[id^='log_row_']").map { |tr| tr["id"] }
      assert_equal admin_project_tracker_log_path(@tracker, anchor: "all-observations"), page.at_css("a.log-newer")["href"]
      assert_nil page.at_css("a.log-older")
    end
  end

  test "a row with broken stored data is drawn, not a 500" do
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Notion.filtered_parent_id(:OBSERVATIONS),
                       data: { "properties" => [] }, project_ids: [@project], occurred_at: 1.day.ago)
    get admin_project_tracker_log_path(@tracker)
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

  def log_module
    page.at_css("#project_log_module")
  end

  test "the tracker page has a Flags module: the counts, the first three flags with why, and a way in" do
    flags = [problem!(name: "Timeline slipping", severity: "Critical", status: "Open", occurrences: 2,
                      flag: "Critical severity problem. Nobody owns it yet.", project_ids: [@project]),
             obs!(name: "n1", valence: "Negative", salience: "High", flag: "High-salience risk.", source: "Twist", observed_at: 1.hour.ago),
             obs!(name: "n2", valence: "Negative", salience: "High", flag: "High-salience risk.", observed_at: 2.hours.ago),
             obs!(name: "n3", valence: "Negative", salience: "High", flag: "High-salience risk.", observed_at: 3.hours.ago)]
    problem!(name: "Closed out", severity: "High", status: "Resolved", flag: "", project_ids: [@project])
    obs!(name: "plain negative", valence: "Negative", salience: "Low", flag: "")
    obs!(name: "a win", valence: "Positive", flag: "")
    obs!(name: "old news", valence: "Negative", salience: "High", flag: "High-salience risk.", observed_at: 40.days.ago)

    get admin_project_tracker_path(@tracker)
    assert_response :success
    assert log_module, "expected the log module on the tracker page"
    assert_equal "Flags", log_module.at_css(".module-header p").text.strip
    assert_equal ["4 Flags", "1 Win in the last 30 days"], log_module.css(".factoid").map { |f| f.text.squish }
    assert_equal flags.first(3).map { |r| "log_flag_#{r.notion_id}" }, log_module.css("tr.log-flag").map { |tr| tr["id"] }
    assert_match(/\ACritical severity problem\. Nobody owns it yet\. Seen 2 times, last on /, log_module.at_css(".log-flag-why").text.strip)
    assert_match(/\AHigh-salience risk\. Seen in Twist on /, log_module.css(".log-flag-why")[1].text.strip)
    assert_equal admin_project_tracker_log_path(@tracker), log_module.css("a").find { |a| a.text.strip == "Open the log →" }["href"]
    assert log_module.css("a").any? { |a| a.text.strip == "See all 4 flags →" }
    assert_no_match(/escalat/i, log_module.text)
    # One parse: nodes of two documents cannot be compared for order.
    doc = page
    ships = doc.css(".panel").find { |panel| panel.at_css("h3")&.text&.strip == "Weekly Ships" }
    assert ships, "expected the Weekly Ships panel"
    assert_equal(-1, doc.at_css("#project_log_module") <=> ships, "the module sits above the Weekly Ships panel")
  end

  test "the module on a tracker with no Notion project says why, and the page still renders" do
    bare, = log_tracker!(name: "Unlinked", project: nil)
    get admin_project_tracker_path(bare)
    assert_response :success
    assert_includes log_module.text, "no Notion project chosen"
    assert_empty log_module.css(".factoid")
    assert log_module.css("a").any? { |a| a["href"] == admin_project_tracker_log_path(bare) }
  end

  test "the module is useful before Valence and Flag exist" do
    obs!(name: "Budget at risk", valence: nil, valence_property: false, type: "Risk", salience: "High")
    obs!(name: "Shipped early", valence: nil, valence_property: false, type: "Win")
    get admin_project_tracker_path(@tracker)
    assert_response :success
    assert_equal ["1 Flag", "1 Win in the last 30 days"], log_module.css(".factoid").map { |f| f.text.squish }
    assert_includes log_module.text, "Budget at risk"
  end

  test "the module with rows but no flags says so in one line, not an error" do
    obs!(name: "Routine note", valence: nil, type: "FYI")
    get admin_project_tracker_path(@tracker)
    assert_response :success
    assert_equal ["0 Flags", "0 Wins in the last 30 days"], log_module.css(".factoid").map { |f| f.text.squish }
    assert_equal 1, log_module.css(".log-no-flags").size
    assert_match(/\ANo flags/, log_module.at_css(".log-no-flags").text.strip)
    assert_empty log_module.css("tr.log-flag")
  end

  test "a scoped grantee sees the module on their tracker" do
    obs!(name: "Mine to read", valence: "Negative", salience: "High")
    trainee = scoped_grantee!
    sign_out @admin
    sign_in trainee
    get admin_project_tracker_path(@tracker)
    assert_response :success
    assert_includes log_module.text, "Mine to read"
  end

  # --- review fixes ----------------------------------------------------------

  UNAVAILABLE = "The project log is unavailable right now."

  # The module's data comes from columns a rolled-back migration takes away.
  # The tracker page is worth more than its newest module.
  test "the tracker page still renders when the log's summary raises, with one line in the module" do
    obs!(name: "NOT-SHOWN", valence: "Negative")
    Stacks::ProjectLog.stubs(:summary).raises(ActiveRecord::StatementInvalid, "PG::UndefinedColumn: column notion_pages.project_ids does not exist")
    Rails.logger.expects(:error).with(regexp_matches(/project log.*#{@tracker.id}.*UndefinedColumn/m)).at_least_once
    get admin_project_tracker_path(@tracker)
    assert_response :success
    assert log_module, "the module is still drawn"
    assert_includes log_module.text, UNAVAILABLE
    assert_empty log_module.css(".factoid")
    assert_empty log_module.css("tr.log-flag")
    assert_not_includes response.body, "UndefinedColumn"
    assert page.css(".panel").any? { |panel| panel.at_css("h3")&.text&.strip == "Weekly Ships" }, "the rest of the page is there"
  end

  test "the log page says it is unavailable, inside the page, when its data cannot be read" do
    obs!(name: "NOT-SHOWN", valence: "Negative")
    %i[empty_reason rows other_problems flags wins].each do |reader|
      Stacks::ProjectLog.any_instance.stubs(reader).raises(ActiveRecord::StatementInvalid, "PG::UndefinedColumn: boom")
      Rails.logger.expects(:error).with(regexp_matches(/project log.*#{@tracker.id}.*UndefinedColumn/m)).at_least_once
      get admin_project_tracker_log_path(@tracker)
      assert_response :success, "#{reader} raising is not a 500"
      assert_includes response.body, UNAVAILABLE
      assert_not_includes response.body, "UndefinedColumn"
      assert page.at_css("a[href='#{admin_project_tracker_path(@tracker)}']"), "the way back to the tracker is there"
      assert_empty page.css("#flags, #wins, #all-observations")
      assert_empty page.css("tr[id^='log_row_']")
      Stacks::ProjectLog.any_instance.unstub(reader)
    end
  end

  test "a request that accepts anything, or names no type, gets the HTML page" do
    row = obs!(name: "Something negative", valence: "Negative")
    ["*/*", "", nil, "text/html", "text/html,application/xhtml+xml,*/*;q=0.8"].each do |accept|
      get admin_project_tracker_log_path(@tracker), headers: accept.nil? ? {} : { "Accept" => accept }
      assert_response :success, "Accept: #{accept.inspect}"
      assert_match(%r{\Atext/html}, response.media_type)
      assert row_for(row), "Accept: #{accept.inspect}"
    end
  end

  test "an explicit other format is still refused, whatever the Accept header" do
    obs!(name: "QUOTED-FROM-A-CHANNEL", valence: "Negative")
    asks = %w[json csv xml].flat_map do |format|
      [[admin_project_tracker_log_path(@tracker, format: format), { "Accept" => "*/*" }],
       ["#{admin_project_tracker_log_path(@tracker)}?format=#{format}", { "Accept" => "*/*" }],
       ["#{admin_project_tracker_log_path(@tracker)}?format=#{format}", {}]]
    end
    asks += [[admin_project_tracker_log_path(@tracker), { "Accept" => "application/json" }],
             [admin_project_tracker_log_path(@tracker), { "Accept" => "text/csv" }]]
    asks.each do |(path, headers)|
      begin
        get path, headers: headers
      rescue ActionController::UnknownFormat, ActionController::RoutingError
        next
      end
      assert_not_equal 200, response.status, "#{path} #{headers.inspect} should not be served"
      assert_not_includes response.body, "QUOTED-FROM-A-CHANNEL"
    end
  end

  test "everything Notion wrote is escaped: the flag's reason and next step, sources, statuses, owners, titles" do
    flagged = problem!(name: "<b>flag</b> title", severity: "High", status: "Open", project_ids: [@project],
                       flag: "<i>reason</i> from Notion.", proposed_action: "<script>alert('next')</script> do it")
    problem = problem!(name: "<b>folded</b> title", severity: "High", status: "<u>status</u>", owner: "<em>owner</em>",
                       flag: "", project_ids: [@project])
    unowned = problem!(name: "Plain", severity: "<i>sev</i>", status: "<s>odd</s>", flag: "", project_ids: [])
    row = obs!(name: "Row", source: "<i>src</i>", valence: "Negative", flag: "<q>why</q>",
               problem_ids: [problem.notion_id, unowned.notion_id])
    tied = obs!(name: "<b>evidence</b>", source: "<i>esrc</i>", source_ref: "javascript:alert(2)", valence: "Negative",
                flag: "", problem_ids: [flagged.notion_id])
    get admin_project_tracker_log_path(@tracker)
    assert_response :success
    %w[<b>folded</b> <u>status</u> <em>owner</em> <i>src</i> <s>odd</s> <i>reason</i> <b>flag</b> <q>why</q> <b>evidence</b> <i>esrc</i>].each do |raw|
      assert_not_includes response.body, raw
    end
    assert_not_includes response.body, "<script>alert('next')"
    assert_empty page.css("tr[id^='log_'] i, tr[id^='log_'] b, tr[id^='log_'] u, tr[id^='log_'] s, tr[id^='log_'] em, tr[id^='log_'] q, tr[id^='log_'] script")
    assert_empty page.css("a[href^='javascript']")
    assert_includes row_for(row).css("td")[2].text, "<i>src</i>"
    assert_includes row_for(row).text, "Folded into <b>folded</b> title"
    assert_includes row_for(row).text, "<u>status</u>"
    assert_includes row_for(row).text, "<s>odd</s>"
    assert_includes flag_for(flagged).at_css(".log-flag-why").text, "<i>reason</i> from Notion."
    assert_includes flag_for(flagged).at_css(".log-flag-next").text, "<script>alert('next')</script> do it"
    assert_includes flag_for(flagged).at_css("#log_evidence_#{tied.notion_id}").text, "<b>evidence</b>"
    assert_nil flag_for(flagged).at_css("#log_evidence_#{tied.notion_id} a.log-source"), "a javascript: address is not a link"
    assert_includes flag_for(row).at_css(".log-flag-why").text, "<q>why</q>"
    listed = page.at_css("#log_problem_#{problem.notion_id}")
    assert_includes listed.text, "Status in Notion: <u>status</u>"

    get admin_project_tracker_path(@tracker)
    assert_not_includes response.body, "<i>reason</i>"
    assert_not_includes response.body, "<b>flag</b>"
    assert_includes log_module.text, "<i>reason</i> from Notion."
  end

  # --- the trackers index ----------------------------------------------------

  def index_cell(tracker)
    found = page.css("#project_tracker_#{tracker.id} td.col-flags")
    assert_equal 1, found.size, "expected one Flags cell for tracker #{tracker.id}"
    found.first
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  # Several trackers, with a Flag in every shape Notion can hold it and rows
  # synced before it existed. Returns the trackers.
  def index_scenario!
    second_project = project_page!(title: "Harvey Retainer").notion_id
    both = ProjectTracker.new(name: "Two projects", notion_project_ids: [@project, second_project])
    both.save!(validate: false)
    quiet, quiet_project = log_tracker!(name: "Quiet")
    unlinked, = log_tracker!(name: "Unlinked", project: nil)

    # Text formula (what Notion holds today): yes, no over an interim yes, and a stale yes.
    flag = problem!(name: "text yes", severity: "Low", flag: "High severity problem. Nobody owns it yet.", project_ids: [@project])
    problem!(name: "text no", severity: "Critical", status: "Open", flag: "", project_ids: [@project])
    problem!(name: "stale yes", severity: "High", status: "Resolved", flag: "High severity problem. Nobody owns it yet.", project_ids: [@project])
    obs!(name: "text yes", valence: "Neutral", salience: "Low", type: "Risk", flag: "High-salience risk.")
    obs!(name: "text no", valence: "Negative", salience: "High", flag: "")
    # Boolean formula and checkbox.
    problem!(name: "formula yes", severity: "Medium", status: "Owned", flag: true, flag_shape: :formula, project_ids: [@project])
    problem!(name: "formula no", severity: "High", status: "Open", flag: false, flag_shape: :formula, project_ids: [@project])
    obs!(name: "checkbox yes", valence: "Positive", flag: true)
    obs!(name: "checkbox no", valence: "Negative", salience: "High", flag: false)
    # No Flag in the stored data: the interim rule.
    problem!(name: "interim yes", severity: "Critical", status: "Open", project_ids: [@project])
    problem!(name: "interim no", severity: "Critical", status: "Owned", project_ids: [@project])
    obs!(name: "interim yes", valence: "Negative", salience: "High")
    obs!(name: "interim no", valence: "Negative", salience: "Medium")
    # De-duplication, from each side, and the window.
    obs!(name: "tied (observation's side)", valence: "Negative", salience: "High", flag: "High-salience risk.", problem_ids: [flag.notion_id])
    reverse = obs!(name: "tied (problem's side)", valence: "Negative", salience: "High")
    problem!(name: "names its source", severity: "High", status: "Open", source_observation_ids: [reverse.notion_id], project_ids: [@project])
    obs!(name: "too old", valence: "Negative", salience: "High", flag: "High-salience risk.", observed_at: 31.days.ago)
    # The second project.
    problem!(name: "retainer flag", severity: "High", status: "Open", flag: "High severity problem. Nobody owns it yet.", project_ids: [second_project])
    observation!(name: "under both", valence: "Negative", salience: "High", project_ids: [@project, second_project], observed_at: 1.day.ago)
    observation!(name: "retainer risk tied to the first flag", valence: "Negative", salience: "High", flag: "High-salience risk.",
                 project_ids: [second_project], observed_at: 1.day.ago, problem_ids: [flag.notion_id])
    observation!(name: "quiet win", valence: "Positive", flag: "", project_ids: [quiet_project], observed_at: 1.day.ago)
    [@tracker, both, quiet, unlinked]
  end

  test "the index has a Flags column right after Notion" do
    get admin_project_trackers_path(scope: "all")
    assert_response :success
    headers = page.css("table.index_table thead th").map { |th| th.text.strip }
    assert_equal %w[Notion Flags], headers[headers.index("Notion"), 2]
  end

  test "the index shows each tracker's flag count as a red pill linking to its log, and nothing when it has none" do
    tracker, both, quiet, unlinked = index_scenario!
    get admin_project_trackers_path(scope: "all")
    assert_response :success
    pill = index_cell(tracker).at_css("a.pill.error")
    assert_equal "8", pill.text.strip
    assert_equal admin_project_tracker_log_path(tracker), pill["href"]
    assert_equal "9", index_cell(both).at_css("a.pill.error").text.strip
    [quiet, unlinked].each do |blank|
      assert_equal "", index_cell(blank).text.strip, blank.name
      assert_empty index_cell(blank).css("a, .pill"), blank.name
    end
  end

  test "the index's count is exactly the number of flags the tracker's log page lists" do
    trackers = index_scenario!
    get admin_project_trackers_path(scope: "all")
    on_index = trackers.to_h { |t| [t.name, index_cell(t).text.strip.to_i] }
    on_page = trackers.to_h do |t|
      get admin_project_tracker_log_path(t)
      assert_response :success
      listed = page.css("#flags tr.log-flag").size
      assert_equal listed.to_s, page.css("#flags .module-header p").last&.text&.strip || "0", "#{t.name}: the header counts the rows" if listed > 0
      [t.name, listed]
    end
    assert_equal on_page, on_index
    assert_equal [8, 9, 0, 0], on_index.values

    get admin_project_tracker_path(trackers.first)
    assert_equal "8 Flags", page.at_css("#project_log_module .factoid").text.squish, "and the tracker page's module agrees"
  end

  test "the index's Flags column is blank, and the index still loads, before the first sync or when the rows cannot be read" do
    tracker, = index_scenario!
    System.first.update!(notion_filtered_sync_marks: {})
    get admin_project_trackers_path(scope: "all")
    assert_response :success
    assert_equal "", index_cell(tracker).text.strip

    Stacks::ProjectLog.stubs(:flag_counts).raises(ActiveRecord::StatementInvalid, "PG::UndefinedColumn: column notion_pages.project_ids does not exist")
    Rails.logger.expects(:error).with(regexp_matches(/project log.*flag counts.*UndefinedColumn/m)).at_least_once
    get admin_project_trackers_path(scope: "all")
    assert_response :success
    assert_equal "", index_cell(tracker).text.strip
    assert_not_includes response.body, "UndefinedColumn"
  end

  test "the index counts flags in the same number of queries for 2 trackers as for 6" do
    make = lambda do |n|
      n.times do
        _, project = log_tracker!
        observation!(valence: "Negative", salience: "High", flag: "High-salience risk.", project_ids: [project], observed_at: 1.day.ago)
        problem!(severity: "High", status: "Open", project_ids: [project])
      end
    end
    make.(1) # with @tracker, two
    get admin_project_trackers_path(scope: "all") # warm up
    at_2 = count_queries { get admin_project_trackers_path(scope: "all") }
    assert_equal 1, page.css("a.log-flag-count").size
    make.(4)
    at_6 = count_queries { get admin_project_trackers_path(scope: "all") }
    assert_equal 5, page.css("a.log-flag-count").size
    assert_equal at_2, at_6, "the Flags column issues a query per row"
  end
end
