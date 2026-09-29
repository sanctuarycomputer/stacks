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
end
