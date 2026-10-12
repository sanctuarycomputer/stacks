require 'test_helper'

# The tracker edit form offers the live Notion Projects pages, and saves the
# one that was picked.
class AdminProjectTrackerSourcesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "srcadmin#{SecureRandom.hex(4)}@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345',
      roles: ['admin']
    )
    sign_in @admin
  end

  def tracker!(**attrs)
    pt = ProjectTracker.new({ name: "Sources #{SecureRandom.hex(2)}" }.merge(attrs))
    pt.save!(validate: false)
    pt
  end

  def with_links!(pt)
    pt.project_tracker_links.create!(name: "MSA", url: "https://x/msa", link_type: :msa)
    pt.project_tracker_links.create!(name: "SOW", url: "https://x/sow", link_type: :sow)
    pt
  end

  def project_page!(title:, stage:)
    NotionPage.create!(
      notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:PROJECTS]),
      page_title: title,
      data: { "last_edited_time" => Time.zone.now.iso8601,
              "properties" => { "Stage" => { "type" => "select", "select" => { "name" => stage } } } }
    )
  end

  test "the edit form lists live Notion projects and leaves out dead ones" do
    live = project_page!(title: "Harvey", stage: "Active")
    project_page!(title: "Longgone", stage: "Passed")
    pt = with_links!(tracker!)

    get edit_admin_project_tracker_path(pt)
    assert_response :success
    assert_select "select#project_tracker_notion_project_id" do
      assert_select "option[value=?]", live.notion_id, text: "Harvey · Active"
      assert_select "option[value='']", text: "No Notion project"
      assert_select "option", text: /Longgone/, count: 0
    end
    assert_includes response.body, "For a Twist channel, paste the channel&#39;s link, like https://twist.com/a/133876/ch/794756/"
  end

  test "the edit form shows the tracker's own page as selected, even when it is no longer live" do
    passed = project_page!(title: "Longgone", stage: "Passed")
    pt = with_links!(tracker!(notion_project_id: passed.notion_id))

    get edit_admin_project_tracker_path(pt)
    assert_response :success
    assert_select "select#project_tracker_notion_project_id option[selected][value=?]", passed.notion_id, text: "Longgone · Passed"
  end

  test "saving the form stores the chosen Notion project, and clearing it removes it" do
    page = project_page!(title: "Harvey", stage: "Active")
    pt = with_links!(tracker!)

    patch admin_project_tracker_path(pt), params: { project_tracker: { notion_project_id: page.notion_id } }
    assert_response :redirect
    assert_equal page.notion_id, pt.reload.notion_project_id

    patch admin_project_tracker_path(pt), params: { project_tracker: { notion_project_id: "" } }
    assert_response :redirect
    assert pt.reload.notion_project_id.blank?
  end
end
