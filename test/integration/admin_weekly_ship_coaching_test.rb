require 'test_helper'

# The grade the nightly grader stores is coaching for the Project Lead. It shows
# on the trackers index ("Last Ship" pill) and on the ship's own page.
class AdminWeeklyShipCoachingTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  STALE = "the last ship is more than 10 days behind the project's last scheduled hours".freeze
  OVERDUE = "the last ship is more than 30 days behind the project's last scheduled hours".freeze
  EXCLUDED_COPY = "This ship is not graded because its email is excluded from Stacks search.".freeze
  PENDING_COPY = "This ship has not been graded yet. Ships are usually graded overnight once they are linked to a project.".freeze
  TOO_OLD_COPY = "This ship has no grade. Only ships sent in the last 14 days are graded, and this one was " \
                 "older than that when it was linked or when grading began.".freeze

  setup do
    @admin = AdminUser.create!(
      email: "shipadmin#{SecureRandom.hex(4)}@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345',
      roles: ['admin']
    )
    sign_in @admin
    @tracker = make_tracker!("Coaching Tracker")
  end

  def make_tracker!(name)
    pt = ProjectTracker.new(name: "#{name} #{SecureRandom.hex(2)}")
    pt.save!(validate: false)
    pt
  end

  def scoring(stars:, continuity_counted: true)
    dims = Stacks::WeeklyShips::Grader::DIMENSIONS.keys.to_h { |k| [k, { "score" => 2, "why" => "Why #{k}." }] }
    dims["timeline"] = { "score" => 0, "why" => "No date is stated." }
    dims["shipped"] = { "score" => 1, "why" => "Mostly activity." }
    { "stars" => stars, "summary" => "Clear asks with owners.", "continuity_counted" => continuity_counted,
      "suggestions" => ["Say when the ticketing decision is due."], "dimensions" => dims }
  end

  def make_doc!(sent_at:, title: "Ship #{SecureRandom.hex(2)}")
    Document.create!(source: :google_groups, external_id: "<g#{SecureRandom.hex(3)}@m>", title: title,
                     occurred_at: sent_at,
                     raw_metadata: { "group_email" => "ships@sanctuary.computer", "gmail_message_ids" => [] })
  end

  def make_ship!(sent_at:, scoring: nil, title: "Ship #{SecureRandom.hex(2)}", tracker: @tracker, document: nil,
                 sent_by_name: "Sam Lead", **attrs)
    ws = WeeklyShip.new(document: document || make_doc!(sent_at: sent_at, title: title), project_tracker: tracker,
                        sent_at: sent_at, matched_by: :llm, sent_by_name: sent_by_name,
                        metadata: scoring ? { "scoring" => scoring } : {}, **attrs)
    ws.via_sweep = true
    ws.save!
    ws
  end

  def exclude!(doc)
    doc.update_columns(excluded: Document.excludeds[:manually_excluded])
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def last_ship_pill
    page.css("#project_tracker_#{@tracker.id} td.col-last_ship .pill").first
  end

  # The panel with this exact title, or nil.
  def panel(title)
    page.css(".panel").find { |p| p.at_css("h3")&.text&.strip == title }
  end

  def scoped_grantee!
    trainee = AdminUser.create!(
      email: "trainee#{SecureRandom.hex(4)}@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345'
    )
    PermissionGrant.create!(admin_user: trainee, permission: "lead", subject: @tracker, granted_by: @admin)
    trainee
  end

  test "the pill colour is the worse of staleness and grade, and every colour but green says why" do
    matrix = {
      fresh: { nil => "exceptional", 5 => "exceptional", 4 => "exceptional", 3 => "at_risk", 2 => "error", 1 => "error" },
      stale: { nil => "at_risk", 5 => "at_risk", 4 => "at_risk", 3 => "at_risk", 2 => "error", 1 => "error" },
      overdue: { nil => "error", 5 => "error", 4 => "error", 3 => "error", 2 => "error", 1 => "error" },
    }
    matrix.each do |staleness, by_stars|
      by_stars.each do |stars, colour|
        cell = "#{staleness} / #{stars.inspect}"
        assert_equal "pill #{colour}", WeeklyShip.pill_class(staleness: staleness, stars: stars), cell
        reason = WeeklyShip.pill_reason(staleness: staleness, stars: stars)
        assert_equal colour == "exceptional", reason.nil?, "#{cell}: only a green pill has no reason"
      end
    end

    reason = ->(staleness, stars) { WeeklyShip.pill_reason(staleness: staleness, stars: stars) }
    assert_equal "Orange: the last ship scored 3 of 5.", reason.(:fresh, 3)
    assert_equal "Red: the last ship scored 2 of 5.", reason.(:fresh, 2)
    assert_equal "Red: the last ship scored 1 of 5.", reason.(:fresh, 1)
    assert_equal "Orange: #{STALE}.", reason.(:stale, nil)
    assert_equal "Orange: #{STALE}.", reason.(:stale, 5)
    assert_equal "Orange: #{STALE}, and it scored 3 of 5.", reason.(:stale, 3)
    assert_equal "Red: the last ship scored 2 of 5.", reason.(:stale, 2)
    assert_equal "Red: #{OVERDUE}.", reason.(:overdue, nil)
    assert_equal "Red: #{OVERDUE}.", reason.(:overdue, 3)
    assert_equal "Red: #{OVERDUE}, and it scored 1 of 5.", reason.(:overdue, 1)
  end

  test "stars that are not a whole number count as ungraded" do
    assert_equal "pill exceptional", WeeklyShip.pill_class(staleness: :fresh, stars: "5")
    assert_equal "pill exceptional", WeeklyShip.pill_class(staleness: :fresh, stars: "1")
    assert_nil WeeklyShip.pill_reason(staleness: :fresh, stars: "1")
    assert_equal "pill at_risk", WeeklyShip.pill_class(staleness: :stale, stars: 2.0)
  end

  test "Last Ship shows the stars first, then when and who, linked to the coaching page" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 3))
    get admin_project_trackers_path(scope: "all")
    assert_response :success
    pill = last_ship_pill
    assert pill, "expected a Last Ship pill for the tracker"
    assert_match(/\A★★★☆☆ · 2 days ago by Sam ↗/, pill.text.squish)
    assert_includes pill["class"], "at_risk" # fresh, but three stars
    assert_equal "Orange: the last ship scored 3 of 5.", pill["title"]
    stars, email = pill.css("a").to_a
    assert_equal admin_weekly_ship_path(ws), stars["href"]
    # Both links say why the pill is orange: they cover most of it.
    assert_equal "Clear asks with owners. Open the coaching for this ship. Orange: the last ship scored 3 of 5.", stars["title"]
    assert_equal "Open the email. Orange: the last ship scored 3 of 5.", email["title"]
    assert_match %r{\Ahttps://groups\.google\.com/}, email["href"]
    # The global `a` rule would otherwise size the pill's text at 18px.
    [stars, email].each { |a| assert_includes a["style"], "font-size: inherit" }
  end

  test "Last Ship for an ungraded ship has no stars and is coloured by staleness alone" do
    make_ship!(sent_at: 2.days.ago)
    get admin_project_trackers_path(scope: "all")
    assert_response :success
    pill = last_ship_pill
    assert_match(/\A2 days ago by Sam/, pill.text.squish)
    assert_not_includes pill.text, "★"
    assert_includes pill["class"], "exceptional"
    assert_nil pill["title"]
  end

  test "Last Ship drops the sender when the ship has none" do
    make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 5), sent_by_name: nil)
    get admin_project_trackers_path(scope: "all")
    assert_response :success
    assert_equal "★★★★★ · 2 days ago ↗", last_ship_pill.text.squish
  end

  test "an admin gets the stars as links on the trackers index and the tracker page" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4))
    [admin_project_trackers_path(scope: "all"), admin_project_tracker_path(@tracker)].each do |path|
      get path
      assert_response :success
      link = page.css("a[href='#{admin_weekly_ship_path(ws)}']").find { |a| a.text.include?("★★★★☆") }
      assert link, "expected linked stars on #{path}"
      assert_includes link["style"], "font-size: inherit"
    end
  end

  test "a reader who cannot open the ship page sees the stars without a link" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 3))
    sign_out @admin
    sign_in scoped_grantee!
    get admin_weekly_ship_path(ws)
    assert_not_equal 200, response.status, "the scoped grantee is not expected to open the ship page"

    [admin_project_trackers_path(scope: "all"), admin_project_tracker_path(@tracker)].each do |path|
      get path
      assert_response :success
      assert_includes response.body, "★★★☆☆", "expected the stars on #{path}"
      assert_not_includes response.body, admin_weekly_ship_path(ws)
    end

    # The pill still says why it is orange, with no link to carry the title.
    get admin_project_trackers_path(scope: "all")
    assert_equal "Orange: the last ship scored 3 of 5.", last_ship_pill["title"]
  end

  test "the ship page coaches in our words: what worked, next time, and each dimension" do
    previous = make_ship!(sent_at: 9.days.ago, scoring: scoring(stars: 5), title: "Last week's ship")
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4), title: "This week's ship",
                    confidence: 0.876, rationale: "Subject names the project.")
    get admin_weekly_ship_path(ws)
    assert_response :success
    body = response.body
    assert_equal "This week's ship", page.at_css("#page_title").text
    assert panel("This ship"), "the top table is titled in our words"
    assert_not_includes body, "Weekly Ship Details"
    assert_includes body, "★★★★☆"
    assert_includes body, "What this ship does well"
    assert_includes body, "Clear asks with owners."
    next_time = panel("For next time")
    assert_includes next_time.text, "Say when the ticketing decision is due."
    assert_includes next_time.at_css("ol")["style"], "font-size: 16px"
    # The admin reset strips list numbers, so each item asks for them back.
    assert_includes next_time.at_css("ol li")["style"], "list-style: decimal"
    assert_includes body, "Shipped, not busy"
    assert_includes body, "Picks up where the last ship left off"
    assert_includes body, "Nailed it"
    assert_includes body, "Partly"
    assert_includes body, "Missing"
    assert_includes body, "No date is stated."
    assert_not_includes body, "0/2"
    assert_not_includes body, "Next week:"
    assert_includes panel("Previous ship").text.squish, "Last week's ship, 9 days ago ★★★★★"
    assert_includes body, admin_weekly_ship_path(previous)
    assert_includes body, "This is coaching for the Project Lead who sent the ship. Stacks scores each ship " \
                          "overnight against what a great ship does. Never share it with the client."
    linking = panel("How this email was linked to the project").text.squish
    assert_includes linking, "Linked By Stacks (automatic)"
    assert_includes linking, "Confidence 88%"
    assert_includes linking, "Subject names the project."
  end

  test "a link a person made says so, and shows no confidence" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4), matched_by: :human)
    get admin_weekly_ship_path(ws)
    assert_response :success
    linking = panel("How this email was linked to the project").text.squish
    assert_includes linking, "Linked By A person"
    assert_not_includes linking, "%"
  end

  test "an earlier ship whose email is excluded from search is not the previous ship" do
    earlier = make_ship!(sent_at: 9.days.ago, scoring: scoring(stars: 5), title: "Excluded earlier ship")
    exclude!(earlier.document)
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4))
    assert_nil ws.previous_ship
    get admin_weekly_ship_path(ws)
    assert_response :success
    assert_nil panel("Previous ship")
    assert_not_includes response.body, "Excluded earlier ship"
  end

  test "a first ship says continuity was not counted and has no previous ship" do
    ws = make_ship!(sent_at: 5.days.ago, scoring: scoring(stars: 4, continuity_counted: false))
    make_ship!(sent_at: 1.day.ago, scoring: scoring(stars: 5), title: "A later ship")
    make_ship!(sent_at: 9.days.ago, scoring: scoring(stars: 5), title: "Another project's ship",
               tracker: make_tracker!("Other Tracker"))
    get admin_weekly_ship_path(ws)
    assert_response :success
    pill = page.css(".pill").find { |p| p.text == "First ship, not counted" }
    assert pill, "expected the first-ship pill"
    assert_includes pill["style"], "background-color: #cfd3d7" # a bare .pill has no background
    assert_not_includes response.body, "Why continuity."
    assert_nil panel("Previous ship")
  end

  test "continuity that was not counted on a later ship says only that" do
    make_ship!(sent_at: 9.days.ago, scoring: scoring(stars: 5), title: "Last week's ship")
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4, continuity_counted: false))
    get admin_weekly_ship_path(ws)
    assert_response :success
    assert page.css(".pill").any? { |p| p.text == "Not counted" }, "expected the not-counted pill"
    assert_not_includes response.body, "First ship"
    assert_not_includes response.body, "Why continuity."
    assert panel("Previous ship")
  end

  test "the previous ship can be on another project the same email is linked to, and says which" do
    other = make_tracker!("Sister Tracker")
    make_ship!(sent_at: 9.days.ago, scoring: scoring(stars: 5), title: "Sister's last ship", tracker: other)
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4))
    make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4), tracker: other, document: ws.document)
    get admin_weekly_ship_path(ws)
    assert_response :success
    assert_includes panel("Previous ship").text.squish, "Sister's last ship, 9 days ago, on #{other.name} ★★★★★"
  end

  test "the previous ship does not name the project when it is this ship's project" do
    make_ship!(sent_at: 9.days.ago, title: "Last week's ship")
    ws = make_ship!(sent_at: 2.days.ago)
    get admin_weekly_ship_path(ws)
    assert_not_includes panel("Previous ship").text, @tracker.name
  end

  test "two earlier emails sent at the same moment give one stable previous ship" do
    at = 9.days.ago
    first = make_ship!(sent_at: at)
    second = make_ship!(sent_at: at)
    ws = make_ship!(sent_at: 2.days.ago)
    assert_equal [first.id, second.id].max, ws.previous_ship.id
  end

  test "a ship with no subject and no sender still renders, here and in the lists" do
    ws = make_ship!(sent_at: Time.zone.local(2026, 10, 5, 12), scoring: scoring(stars: 4), sent_by_name: nil)
    ws.document.update_columns(title: nil)
    later = make_ship!(sent_at: Time.zone.local(2026, 10, 6, 12))

    get admin_weekly_ship_path(ws)
    assert_response :success
    assert_equal "Weekly ship, October 5, 2026", page.at_css("#page_title").text
    assert_includes panel("This ship").text, "Unknown sender"

    get admin_weekly_ship_path(later)
    assert_response :success
    assert_includes panel("Previous ship").text, "Weekly ship, October 5, 2026"

    get admin_weekly_ships_path
    assert_response :success
    row = page.at_css("#weekly_ship_#{ws.id}").text
    assert_includes row, "Weekly ship, October 5, 2026"
    assert_includes row, "Unknown sender"

    get admin_project_tracker_path(@tracker)
    assert_response :success
    ships = panel("Weekly Ships").text
    assert_includes ships, "Weekly ship, October 5, 2026"
    assert_includes ships, "Unknown sender"
  end

  test "the sender falls back to the email address" do
    ws = make_ship!(sent_at: 2.days.ago, sent_by_name: "", sent_by_email: "sam@sanctuary.computer")
    assert_equal "sam@sanctuary.computer", ws.sender_label
    assert_equal "Unknown sender", WeeklyShip.new.sender_label
    # The pill shows the part before the @, not the whole address.
    get admin_project_trackers_path(scope: "all")
    assert_match(/\A2 days ago by sam ↗/, last_ship_pill.text.squish)
  end

  test "the coaching text is set at a readable size" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4))
    get admin_weekly_ship_path(ws)
    assert_includes panel("What this ship does well").at_css("p")["style"], "font-size: 16px"
  end

  test "dimensions that are not a set of scores leave How it scored off the page" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4).merge("dimensions" => []))
    get admin_weekly_ship_path(ws)
    assert_response :success
    assert_nil panel("How it scored")
    assert panel("What this ship does well")
  end

  test "a dimension without a real score is left out; the rest still show" do
    odd = scoring(stars: 4)
    odd["dimensions"]["money"] = { "why" => "Why with no score." }
    odd["dimensions"]["readable"] = "great"
    odd["dimensions"]["asks"] = { "score" => "2", "why" => "Why with a text score." }
    odd["dimensions"]["next_week"] = { "score" => 7, "why" => "Why out of range." }
    ws = make_ship!(sent_at: 2.days.ago, scoring: odd)
    get admin_weekly_ship_path(ws)
    assert_response :success
    scored = panel("How it scored").text
    assert_includes scored, "Shipped, not busy"
    assert_includes scored, "Timeline is explicit"
    ["Money is visible", "Readable by the client", "Risks and asks are visible", "Next week is a promise",
     "Why with no score.", "Why with a text score.", "Why out of range."].each do |gone|
      assert_not_includes scored, gone
    end
  end

  test "For next time keeps only real suggestions, and goes when there are none" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4).merge("suggestions" => ["", nil, 3, "Name the launch date."]))
    get admin_weekly_ship_path(ws)
    assert_response :success
    assert_equal ["Name the launch date."], panel("For next time").css("li").map(&:text)

    none = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4).merge("suggestions" => [nil, " "]))
    get admin_weekly_ship_path(none)
    assert_response :success
    assert_nil panel("For next time")
  end

  test "stars stored as text are not a grade" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: "5"))
    get admin_weekly_ship_path(ws)
    assert_response :success
    assert panel("Not graded")
    get admin_project_trackers_path(scope: "all")
    assert_response :success
    assert_not_includes last_ship_pill.text, "★"
    assert_includes last_ship_pill["class"], "exceptional"
  end

  def assert_not_graded(ws, copy)
    get admin_weekly_ship_path(ws)
    assert_response :success
    text = panel("Not graded").text.squish
    assert_includes panel("Not graded").at_css("p")["style"], "font-size: 16px"
    [EXCLUDED_COPY, PENDING_COPY, TOO_OLD_COPY].each do |sentence|
      if sentence == copy
        assert_includes text, sentence
      else
        assert_not_includes text, sentence
      end
    end
    assert_nil panel("For next time")
  end

  test "a recent ungraded ship says it has not been graded yet" do
    assert_not_graded make_ship!(sent_at: 2.days.ago), PENDING_COPY
  end

  test "an old ungraded ship says only recent ships are graded" do
    assert_not_graded make_ship!(sent_at: 40.days.ago), TOO_OLD_COPY
  end

  test "an ungraded ship whose email is excluded from search says so, however recent" do
    recent = make_ship!(sent_at: 2.days.ago)
    exclude!(recent.document)
    assert_not_graded recent, EXCLUDED_COPY
    old = make_ship!(sent_at: 40.days.ago)
    exclude!(old.document)
    assert_not_graded old, EXCLUDED_COPY
  end

  test "a link added after the email was graded shows the email's grade" do
    graded = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4))
    late = make_ship!(sent_at: 2.days.ago, tracker: make_tracker!("Late Tracker"), document: graded.document)
    get admin_weekly_ship_path(late)
    assert_response :success
    assert_nil panel("Not graded")
    assert_includes panel("This ship").text, "★★★★☆"
    assert_includes response.body, "Clear asks with owners."
  end

  test "the tracker page's Weekly Ships panel speaks to the Project Lead" do
    make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4))
    get admin_project_tracker_path(@tracker)
    assert_response :success
    ships = panel("Weekly Ships")
    assert_includes ships.css("th").map(&:text), "Feedback for the Project Lead"
    assert_includes ships.text, "Grades are coaching for the Project Lead who sent the ship, scored overnight " \
                                "by a model. Never share them with the client."
    assert_not_includes ships.text, "for the sender"
    open = ships.css("a").find { |a| a.text.include?("Open") }
    assert_includes open["style"], "white-space: nowrap"
  end

  test "the Weekly Ships list links the stars at the size of the text around them" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4))
    ShipScan.create!(document: ws.document, outcome: :linked, scanned_at: Time.zone.now)
    get admin_ship_scans_path(scope: "linked")
    assert_response :success
    link = page.css("a[href='#{admin_weekly_ship_path(ws)}']").find { |a| a.text.include?("★") }
    assert_includes link["style"], "font-size: inherit"
  end

  test "the page guide covers every dimension the grader scores" do
    assert_equal Stacks::WeeklyShips::Grader::DIMENSIONS.keys, Stacks::WeeklyShips::Grader::GUIDE.keys
  end
end
