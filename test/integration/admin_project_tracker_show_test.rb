require 'test_helper'

# The tracker show page renders `notes` as Markdown. RDiscount.new(nil) raises
# TypeError, and project_trackers.notes is nullable — so a tracker whose notes
# were never filled in 500s the page. Every other RDiscount call site in
# app/views/admin guards its input; this one was the outlier.
class AdminProjectTrackerShowTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "trkadmin#{SecureRandom.hex(4)}@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345',
      roles: ['admin']
    )
    sign_in @admin
  end

  def make_tracker!(notes:)
    pt = ProjectTracker.new(name: "Notes Tracker #{SecureRandom.hex(2)}")
    pt.save!(validate: false)
    pt.update_column(:notes, notes)
    pt
  end

  test "the show page renders for a tracker whose notes were never set" do
    pt = make_tracker!(notes: nil)
    get admin_project_tracker_path(pt)
    assert_response :success
  end

  test "the show page renders for a tracker with blank notes" do
    pt = make_tracker!(notes: "")
    get admin_project_tracker_path(pt)
    assert_response :success
  end

  test "the show page still renders notes as markdown when they are present" do
    pt = make_tracker!(notes: "A **bold** note")
    get admin_project_tracker_path(pt)
    assert_response :success
    assert_includes response.body, "<strong>bold</strong>"
  end

  test "the copy button embeds the model's weekly ship block and the money table shows a monthly budget" do
    pt = make_tracker!(notes: nil)
    pt.update_columns(monthly_budget_low_end: 6000, monthly_budget_high_end: 6000)
    get admin_project_tracker_path(pt)
    assert_response :success
    # The JS template literal is fed by ProjectTracker#weekly_ship_block (escape_javascript'd).
    assert_includes response.body, "Hours Progress\\nTrailing 7 days:"
    assert_includes response.body, "Spend this Month:"
    # escape_javascript turns "$" into "\$" inside the template literal.
    assert_includes response.body, "Monthly Budget: \\$6,000.00"
    assert_includes response.body, "Monthly Budget Low End"
    assert_not_includes response.body, "Total Spend to Date: \\$"
  end

  test "the Weekly Ships panel shows each ship's grade and the feedback for the sender" do
    pt = make_tracker!(notes: nil)
    doc = Document.create!(source: :google_groups, external_id: "<g#{SecureRandom.hex(3)}@m>", title: "Graded ship",
                           occurred_at: 2.days.ago,
                           raw_metadata: { "group_email" => "ships@sanctuary.computer", "gmail_message_ids" => [] })
    ws = WeeklyShip.new(document: doc, project_tracker: pt, sent_at: 2.days.ago, matched_by: :llm, sent_by_name: "Sam",
                        metadata: { "scoring" => { "stars" => 4, "summary" => "Clear asks with owners.",
                                                   "suggestions" => ["Say when the ticketing decision is due."] } })
    ws.via_sweep = true
    ws.save!

    get admin_project_tracker_path(pt)
    assert_response :success
    assert_includes response.body, "★★★★☆"
    assert_includes response.body, "Clear asks with owners."
    assert_includes response.body, "Say when the ticketing decision is due."
  end
end
