require 'test_helper'

# The tracker edit form offers the live Notion Projects pages, and saves the
# one or many that were picked.
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

  SELECT = "select#project_tracker_notion_project_ids".freeze

  test "the edit form lists live Notion projects in a multiple select and leaves out dead ones" do
    live = project_page!(title: "Harvey", stage: "Active")
    project_page!(title: "Longgone", stage: "Passed")
    pt = with_links!(tracker!)

    get edit_admin_project_tracker_path(pt)
    assert_response :success
    assert_select "#{SELECT}[multiple][name='project_tracker[notion_project_ids][]']" do
      assert_select "option[value=?]", live.notion_id, text: "Harvey · Active"
      assert_select "option[value='']", count: 0
      assert_select "option[selected]", count: 0
      assert_select "option", text: /Longgone/, count: 0
    end
    assert_select "label[for=project_tracker_notion_project_ids]", text: "Notion Projects"
    assert_includes response.body, "This project&#39;s page or pages in the Notion Projects database. Stacksbot files what it sees about a project under them. Hold Cmd or Ctrl to choose more than one."
    assert_includes response.body, "For a Twist channel, paste the channel&#39;s link, like https://twist.com/a/133876/ch/794756/"
  end

  test "the form posts a blank beside the select, so choosing nothing still submits the field" do
    get edit_admin_project_tracker_path(with_links!(tracker!))
    assert_select "input[type=hidden][name='project_tracker[notion_project_ids][]'][value='']", count: 1
  end

  test "the edit form shows both of the tracker's pages as selected, even one that is no longer live" do
    live = project_page!(title: "Harvey", stage: "Active")
    passed = project_page!(title: "Longgone", stage: "Passed")
    other = project_page!(title: "Someone Else", stage: "Active")
    pt = with_links!(tracker!(notion_project_ids: [passed.notion_id, live.notion_id]))

    get edit_admin_project_tracker_path(pt)
    assert_response :success
    assert_select "#{SELECT} option[selected]", count: 2
    assert_select "#{SELECT} option[selected][value=?]", passed.notion_id, text: "Longgone · Passed"
    assert_select "#{SELECT} option[selected][value=?]", live.notion_id, text: "Harvey · Active"
    assert_select "#{SELECT} option[value=?]:not([selected])", other.notion_id
  end

  test "saving the form stores two Notion projects" do
    a = project_page!(title: "Harvey", stage: "Active")
    b = project_page!(title: "Harvey Retainer", stage: "Active")
    pt = with_links!(tracker!)

    # As the browser sends it: the hidden blank, then each chosen option.
    patch admin_project_tracker_path(pt), params: { project_tracker: { notion_project_ids: ["", a.notion_id, b.notion_id] } }
    assert_response :redirect
    assert_equal [a.notion_id, b.notion_id], pt.reload.notion_project_ids
  end

  test "submitting the form with nothing chosen stores an empty list" do
    page = project_page!(title: "Harvey", stage: "Active")
    pt = with_links!(tracker!(notion_project_ids: [page.notion_id]))

    patch admin_project_tracker_path(pt), params: { project_tracker: { notion_project_ids: [""] } }
    assert_response :redirect
    assert_equal [], pt.reload.notion_project_ids
  end

  test "a form that does not send the field leaves the Notion projects alone" do
    page = project_page!(title: "Harvey", stage: "Active")
    pt = with_links!(tracker!(notion_project_ids: [page.notion_id]))

    patch admin_project_tracker_path(pt), params: { project_tracker: { notes: "Only the notes" } }
    assert_response :redirect
    assert_equal [page.notion_id], pt.reload.notion_project_ids
    assert_equal "Only the notes", pt.notes
  end

  test "an id that is not a Projects page is refused by the form" do
    pt = with_links!(tracker!)

    patch admin_project_tracker_path(pt), params: { project_tracker: { notion_project_ids: ["", "not-a-page"] } }
    assert_response :success
    assert_includes response.body, "must be pages in the Notion Projects database"
    assert_equal [], pt.reload.notion_project_ids
  end
end
