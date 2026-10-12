require 'test_helper'

# The grade the nightly grader stores is coaching for the Project Lead. It shows
# on the trackers index ("Last Ship" pill) and on the ship's own page.
class AdminWeeklyShipCoachingTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "shipadmin#{SecureRandom.hex(4)}@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345',
      roles: ['admin']
    )
    sign_in @admin
    @tracker = ProjectTracker.new(name: "Coaching Tracker #{SecureRandom.hex(2)}")
    @tracker.save!(validate: false)
  end

  def scoring(stars:, continuity_counted: true)
    dims = Stacks::WeeklyShips::Grader::DIMENSIONS.keys.to_h { |k| [k, { "score" => 2, "why" => "Why #{k}." }] }
    dims["timeline"] = { "score" => 0, "why" => "No date is stated." }
    dims["shipped"] = { "score" => 1, "why" => "Mostly activity." }
    { "stars" => stars, "summary" => "Clear asks with owners.", "continuity_counted" => continuity_counted,
      "suggestions" => ["Say when the ticketing decision is due."], "dimensions" => dims }
  end

  def make_ship!(sent_at:, scoring: nil, title: "Ship #{SecureRandom.hex(2)}")
    doc = Document.create!(source: :google_groups, external_id: "<g#{SecureRandom.hex(3)}@m>", title: title,
                           occurred_at: sent_at,
                           raw_metadata: { "group_email" => "ships@sanctuary.computer", "gmail_message_ids" => [] })
    ws = WeeklyShip.new(document: doc, project_tracker: @tracker, sent_at: sent_at, matched_by: :llm,
                        sent_by_name: "Sam Lead", metadata: scoring ? { "scoring" => scoring } : {})
    ws.via_sweep = true
    ws.save!
    ws
  end

  def last_ship_pill
    Nokogiri::HTML(response.body).css("#project_tracker_#{@tracker.id} td.col-last_ship .pill").first
  end

  test "the pill colour is the worse of staleness and grade" do
    assert_equal "pill exceptional", WeeklyShip.pill_class(staleness: :fresh, stars: 5)
    assert_equal "pill exceptional", WeeklyShip.pill_class(staleness: :fresh, stars: 4)
    assert_equal "pill exceptional", WeeklyShip.pill_class(staleness: :fresh, stars: nil)
    assert_equal "pill at_risk", WeeklyShip.pill_class(staleness: :fresh, stars: 3)
    assert_equal "pill error", WeeklyShip.pill_class(staleness: :fresh, stars: 2)
    assert_equal "pill at_risk", WeeklyShip.pill_class(staleness: :stale, stars: 5)
    assert_equal "pill error", WeeklyShip.pill_class(staleness: :stale, stars: 1)
    assert_equal "pill error", WeeklyShip.pill_class(staleness: :overdue, stars: 5)
    assert_equal "pill at_risk", WeeklyShip.pill_class(staleness: :stale, stars: nil)
  end

  test "Last Ship shows the stars first, then when and who, linked to the coaching page" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 3))
    get admin_project_trackers_path(scope: "all")
    assert_response :success
    pill = last_ship_pill
    assert pill, "expected a Last Ship pill for the tracker"
    assert_match(/\A★★★☆☆ · 2 days ago by Sam/, pill.text.squish)
    assert_includes pill["class"], "at_risk" # fresh, but three stars
    stars = pill.css("a").first
    assert_equal admin_weekly_ship_path(ws), stars["href"]
    assert_equal "Clear asks with owners.", stars["title"]
  end

  test "Last Ship for an ungraded ship has no stars and is coloured by staleness alone" do
    make_ship!(sent_at: 2.days.ago)
    get admin_project_trackers_path(scope: "all")
    assert_response :success
    pill = last_ship_pill
    assert_match(/\A2 days ago by Sam/, pill.text.squish)
    assert_not_includes pill.text, "★"
    assert_includes pill["class"], "exceptional"
  end

  test "the ship page coaches in our words: what worked, next time, and each dimension" do
    previous = make_ship!(sent_at: 9.days.ago, scoring: scoring(stars: 5), title: "Last week's ship")
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4))
    get admin_weekly_ship_path(ws)
    assert_response :success
    body = response.body
    assert_includes body, "★★★★☆"
    assert_includes body, "What this ship does well"
    assert_includes body, "Clear asks with owners."
    assert_includes body, "For next time"
    assert_includes body, "Say when the ticketing decision is due."
    assert_includes body, "Shipped, not busy"
    assert_includes body, "Picks up where the last ship left off"
    assert_includes body, "Nailed it"
    assert_includes body, "Partly"
    assert_includes body, "Missing"
    assert_includes body, "No date is stated."
    assert_not_includes body, "0/2"
    assert_not_includes body, "Next week:"
    assert_includes body, "Last week&#39;s ship"
    assert_includes body, admin_weekly_ship_path(previous)
    assert_includes body, "Never share it with the client."
  end

  test "a first ship says continuity was not counted" do
    ws = make_ship!(sent_at: 2.days.ago, scoring: scoring(stars: 4, continuity_counted: false))
    get admin_weekly_ship_path(ws)
    assert_response :success
    assert_includes response.body, "First ship, not counted"
    assert_not_includes response.body, "Why continuity."
    assert_not_includes response.body, "Previous ship"
  end

  test "an ungraded ship's page renders and says it is not graded" do
    ws = make_ship!(sent_at: 40.days.ago)
    get admin_weekly_ship_path(ws)
    assert_response :success
    assert_includes response.body, "Not graded"
    assert_not_includes response.body, "For next time"
  end

  test "the page guide covers every dimension the grader scores" do
    assert_equal Stacks::WeeklyShips::Grader::DIMENSIONS.keys, Stacks::WeeklyShips::Grader::GUIDE.keys
  end
end
