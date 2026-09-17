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
end
