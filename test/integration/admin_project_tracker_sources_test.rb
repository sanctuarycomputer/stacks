require 'test_helper'

# The tracker edit form offers the live Notion Projects pages, and saves the
# one or many that were picked. The trackers index links to each project's
# Twist channels and Notion pages.
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

  # ---- the trackers index: where each project's conversation lives ----------

  def twist_link!(pt, channel_id, name: "Twist Channel")
    pt.project_tracker_links.create!(name: name, url: "https://twist.com/a/133876/ch/#{channel_id}/", link_type: :twist_channel)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def cell(pt, column)
    found = page.css("#project_tracker_#{pt.id} td.col-#{column}")
    assert_equal 1, found.size, "expected one #{column} cell for tracker #{pt.id}"
    found.first
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  def complete!(pt)
    pt.update_column(:work_completed_at, 2.months.ago)
    ProjectCapsule.create!(
      project_tracker: pt,
      client_feedback_survey_status: :opt_out_of_sending_client_feedback_survey,
      internal_marketing_status: :case_study_scheduled_with_communications_team,
      capsule_status: :project_capsule_shared_with_garden3d_on_twist,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
      client_satisfaction_status: :satisfied,
    )
    pt
  end

  test "the index shows each Twist channel as a link, in channel-id order" do
    pt = tracker!
    twist_link!(pt, 794756, name: "Harvey Internal")
    twist_link!(pt, 5, name: "Harvey Client")

    get admin_project_trackers_path(scope: "all")
    assert_response :success
    links = cell(pt, "twist").css("a")
    assert_equal ["Harvey Client ↗", "Harvey Internal ↗"], links.map(&:text)
    assert_equal ["https://twist.com/a/133876/ch/5/", "https://twist.com/a/133876/ch/794756/"], links.map { |a| a["href"] }
    links.each do |a|
      assert_equal "_blank", a["target"]
      assert_equal "block", a["class"]
      assert_equal "white-space:nowrap", a["style"]
    end
    assert_empty cell(pt, "twist").css(".pill")
  end

  test "the index says Stacksbot is not invited beside a channel it cannot read, and only that one" do
    pt = tracker!
    twist_link!(pt, 5, name: "Harvey Client")
    twist_link!(pt, 794756, name: "Harvey Internal")
    pt.update_columns(twist_channels_inaccessible: [794756], twist_channel_checked_at: Time.zone.now)

    get admin_project_trackers_path(scope: "all")
    twist = cell(pt, "twist")
    assert_equal ["Stacksbot not invited"], twist.css("span.pill.error").map(&:text)
    # Element order in the cell: the readable channel, the unreadable one, its pill.
    assert_equal ["Harvey Client ↗", "Harvey Internal ↗", "Stacksbot not invited"], twist.css("a, span.pill").map(&:text)
  end

  test "the index flags a tracker with no Twist channel and no Notion project" do
    pt = with_links!(tracker!)

    get admin_project_trackers_path(scope: "all")
    assert_equal ["No Twist Channel"], cell(pt, "twist").css("span.pill.error").map(&:text)
    assert_empty cell(pt, "twist").css("a")
    assert_equal ["No Notion Project"], cell(pt, "notion").css("span.pill.error").map(&:text)
    assert_empty cell(pt, "notion").css("a")
  end

  test "the index shows each Notion project as a link to its page" do
    a = project_page!(title: "Harvey", stage: "Active")
    b = project_page!(title: "Harvey Retainer", stage: "Completed")
    pt = tracker!(notion_project_ids: [b.notion_id, a.notion_id])

    get admin_project_trackers_path(scope: "all")
    links = cell(pt, "notion").css("a")
    assert_equal ["Harvey Retainer ↗", "Harvey ↗"], links.map(&:text)
    assert_equal [b.notion_link, a.notion_link], links.map { |l| l["href"] }
    links.each do |l|
      assert_equal "_blank", l["target"]
      assert_equal "block", l["class"]
      assert_equal "white-space:nowrap", l["style"]
    end
    assert_empty cell(pt, "notion").css(".pill")
  end

  test "the index says so when a chosen Notion page has been removed" do
    kept = project_page!(title: "Harvey", stage: "Active")
    gone = project_page!(title: "Longgone", stage: "Active")
    pt = tracker!(notion_project_ids: [kept.notion_id, gone.notion_id])
    gone.destroy
    assert gone.reload.deleted?, "the page is soft-deleted"

    get admin_project_trackers_path(scope: "all")
    notion = cell(pt, "notion")
    assert_equal ["Harvey ↗"], notion.css("a").map(&:text)
    assert_equal ["Removed from Notion"], notion.css("span.pill.error").map(&:text)
    assert_not_includes notion.text, "Longgone"
  end

  test "an internal-client tracker with nothing linked shows a dash, not an error" do
    pt = with_links!(tracker!)
    ProjectTracker.any_instance.stubs(:internal_client?).returns(true)

    get admin_project_trackers_path(scope: "all")
    %w[twist notion].each do |column|
      assert_equal "—", cell(pt, column).text.strip
      assert_empty cell(pt, column).css(".pill")
    end
  end

  test "an internal-client tracker that does have links shows them" do
    project = project_page!(title: "Index", stage: "Active")
    pt = tracker!(notion_project_ids: [project.notion_id])
    twist_link!(pt, 5, name: "Index Space")
    ProjectTracker.any_instance.stubs(:internal_client?).returns(true)

    get admin_project_trackers_path(scope: "all")
    assert_equal ["Index Space ↗"], cell(pt, "twist").css("a").map(&:text)
    assert_equal ["Index ↗"], cell(pt, "notion").css("a").map(&:text)
  end

  test "the Complete tab shows a dash for a tracker with nothing linked, and links when it has them" do
    bare = complete!(with_links!(tracker!))
    project = project_page!(title: "Wrapped", stage: "Completed")
    linked = complete!(tracker!(notion_project_ids: [project.notion_id]))
    twist_link!(linked, 5, name: "Wrapped Client")

    get admin_project_trackers_path(scope: "complete")
    assert_response :success
    %w[twist notion].each do |column|
      assert_equal "—", cell(bare, column).text.strip
      assert_empty cell(bare, column).css(".pill")
    end
    assert_equal ["Wrapped Client ↗"], cell(linked, "twist").css("a").map(&:text)
    assert_equal ["Wrapped ↗"], cell(linked, "notion").css("a").map(&:text)
  end

  test "a channel name is shown as text, never as markup" do
    pt = tracker!
    twist_link!(pt, 5, name: "<script>alert(1)</script> & co")

    get admin_project_trackers_path(scope: "all")
    assert_not_includes response.body, "<script>alert(1)</script>"
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt; &amp; co ↗"
    assert_equal ["<script>alert(1)</script> & co ↗"], cell(pt, "twist").css("a").map(&:text)
    assert_empty cell(pt, "twist").css("script")
  end

  test "a Notion page title is shown as text, never as markup" do
    page = project_page!(title: "<script>alert(1)</script> & co", stage: "Active")
    pt = tracker!
    pt.update_columns(notion_project_ids: [page.notion_id])

    get admin_project_trackers_path(scope: "all")
    assert_not_includes response.body, "<script>alert(1)</script>"
    assert_equal ["<script>alert(1)</script> & co ↗"], cell(pt, "notion").css("a").map(&:text)
    assert_empty cell(pt, "notion").css("script")
  end

  test "blank entries in a tracker's Notion projects are ignored, not shown as removed" do
    pt = tracker!
    pt.update_columns(notion_project_ids: [""])
    get admin_project_trackers_path(scope: "all")
    assert_equal ["No Notion Project"], cell(pt, "notion").css("span.pill.error").map(&:text)
  end

  test "a Twist link with no name still reads as a link" do
    pt = tracker!
    link = twist_link!(pt, 5)
    link.update_columns(name: "")
    get admin_project_trackers_path(scope: "all")
    assert_equal ["Twist Channel ↗"], cell(pt, "twist").css("a").map(&:text)
  end

  test "the Runn.io Project column is still there, ahead of Twist and Notion" do
    pt = tracker!
    get admin_project_trackers_path(scope: "all")
    assert_equal ["No Runn.io Project Connected"], cell(pt, "runn_io_project").css("span.pill.error").map(&:text)
    headers = page.css("table.index_table thead th").map { |th| th.text.strip }
    at = headers.index("Runn.io Project")
    assert_equal ["Runn.io Project", "Twist", "Notion"], headers[at, 3]
  end

  test "the index issues the same number of queries for 2 trackers as for 6" do
    sourced = lambda do |i|
      a = project_page!(title: "Project #{i}", stage: "Active")
      b = project_page!(title: "Project #{i} Retainer", stage: "Active")
      pt = with_links!(tracker!(notion_project_ids: [a.notion_id, b.notion_id]))
      twist_link!(pt, 1000 + i, name: "Channel #{i}")
      twist_link!(pt, 2000 + i, name: "Channel #{i} Client")
      pt
    end
    2.times { |i| sourced.call(i) }
    get admin_project_trackers_path(scope: "all") # warm up
    at_2 = count_queries { get admin_project_trackers_path(scope: "all") }
    assert_equal 2, page.css("tr[id^='project_tracker_']").size
    assert_includes response.body, "Channel 1 Client ↗"

    (2...6).each { |i| sourced.call(i) }
    at_6 = count_queries { get admin_project_trackers_path(scope: "all") }
    assert_equal 6, page.css("tr[id^='project_tracker_']").size
    assert_includes response.body, "Project 5 Retainer ↗"
    assert_equal at_2, at_6, "the page issues a query per row"
  end
end
