require 'test_helper'

# A tracker names where its conversation lives: one Twist channel link, in one
# stored shape, and one Notion Projects page.
class ProjectTrackerSourcesTest < ActiveSupport::TestCase
  CHANNEL = "https://twist.com/a/133876/ch/794756/".freeze
  SHAPE_ERROR = "must be a Twist channel in our workspace, like https://twist.com/a/133876/ch/794756/".freeze

  def tracker!(**attrs)
    pt = ProjectTracker.new({ name: "Sources" }.merge(attrs))
    pt.save!(validate: false)
    pt
  end

  def with_links!(pt)
    pt.project_tracker_links.create!(name: "MSA", url: "https://x/msa", link_type: :msa)
    pt.project_tracker_links.create!(name: "SOW", url: "https://x/sow", link_type: :sow)
    pt
  end

  def twist_link!(pt, url = CHANNEL)
    pt.project_tracker_links.create!(name: "Twist Channel", url: url, link_type: :twist_channel)
  end

  def twist_link(pt, url)
    pt.project_tracker_links.build(name: "Twist Channel", url: url, link_type: :twist_channel)
  end

  # ---- the stored shape ----------------------------------------------------

  test "a canonical channel URL saves unchanged and gives the channel id" do
    pt = tracker!
    link = twist_link!(pt)
    assert_equal CHANNEL, link.reload.url
    assert_equal 794756, link.twist_channel_id
    assert_equal 794756, pt.reload.twist_channel_id
  end

  test "a channel URL without its trailing slash is saved in the canonical shape" do
    link = twist_link!(tracker!, "https://twist.com/a/133876/ch/794756")
    assert_equal CHANNEL, link.reload.url
  end

  test "a padded channel URL is stripped, then tidied" do
    link = twist_link!(tracker!, "  https://twist.com/a/133876/ch/794756  ")
    assert_equal CHANNEL, link.reload.url
  end

  test "a thread URL is cut back to its channel" do
    link = twist_link!(tracker!, "https://twist.com/a/133876/ch/355509/t/6877281/")
    assert_equal "https://twist.com/a/133876/ch/355509/", link.reload.url
  end

  test "a comment URL and a URL with a query string are cut back to the channel" do
    comment = twist_link!(tracker!, "https://twist.com/a/133876/ch/355509/t/6877281/c/9/")
    assert_equal "https://twist.com/a/133876/ch/355509/", comment.reload.url

    query = twist_link!(tracker!, "https://twist.com/a/133876/ch/355509/?tab=threads#top")
    assert_equal "https://twist.com/a/133876/ch/355509/", query.reload.url
  end

  test "a channel in another workspace is refused, with the expected shape in the message" do
    link = twist_link(tracker!, "https://twist.com/a/1/ch/2/")
    assert_not link.valid?
    assert_equal [SHAPE_ERROR], link.errors[:url]
    assert_nil link.twist_channel_id
  end

  test "anything that is not an https channel link in our workspace is refused" do
    pt = tracker!
    [
      "https://example.com/a/133876/ch/2/",
      "https://twist.com.evil.com/a/133876/ch/2/",
      "https://eviltwist.com/a/133876/ch/2/",
      "https://twist.com/a/133876/ch/0/",
      "http://twist.com/a/133876/ch/2/",
      "https://twist.com/a/133876/ch/abc/",
      "https://twist.com/a/133876/",
    ].each do |url|
      link = twist_link(pt, url)
      assert_not link.valid?, "#{url} should be invalid"
      assert_includes link.errors[:url], SHAPE_ERROR, url
    end
  end

  test "links of other types are left as they were typed" do
    pt = tracker!
    sow = pt.project_tracker_links.create!(name: "SOW", url: "https://twist.com/a/133876/ch/355509/t/6877281/", link_type: :sow)
    assert_equal "https://twist.com/a/133876/ch/355509/t/6877281/", sow.reload.url
    assert_nil sow.twist_channel_id

    other = pt.project_tracker_links.create!(name: "Site", url: "https://example.com/a/1/ch/2", link_type: :other)
    assert_equal "https://example.com/a/1/ch/2", other.reload.url
  end

  # ---- one per tracker -----------------------------------------------------

  test "a tracker with two Twist channel links is invalid" do
    pt = with_links!(tracker!)
    twist_link!(pt)
    twist_link(pt, "https://twist.com/a/133876/ch/11/")
    assert_not pt.valid?
    assert_includes pt.errors[:base], "A project can have only one Twist channel link."
  end

  test "replacing the Twist channel link in one save works" do
    pt = with_links!(tracker!)
    old = twist_link!(pt)
    pt.reload.update!(project_tracker_links_attributes: [
      { id: old.id, _destroy: "1" },
      { name: "Twist Channel", link_type: "twist_channel", url: "https://twist.com/a/133876/ch/11/" },
    ])
    links = pt.reload.project_tracker_links.select(&:twist_channel?)
    assert_equal ["https://twist.com/a/133876/ch/11/"], links.map(&:url)
    assert_equal 11, pt.twist_channel_id
  end

  test "twist_channel_id is nil with no Twist link" do
    assert_nil with_links!(tracker!).twist_channel_id
  end

  # ---- the stored access answer follows the link -----------------------------

  def answered!(pt)
    pt.update_columns(twist_channel_accessible: false, twist_channel_checked_at: Time.zone.now)
  end

  def assert_forgotten(pt, message)
    pt.reload
    assert_nil pt.twist_channel_accessible, message
    assert_nil pt.twist_channel_checked_at, message
  end

  test "changing, destroying or adding a Twist link forgets the access answer" do
    pt = tracker!
    link = twist_link!(pt)

    answered!(pt)
    link.update!(url: "https://twist.com/a/133876/ch/11/")
    assert_forgotten pt, "after changing the URL"

    answered!(pt)
    # A fresh instance: the one above still remembers its URL change.
    ProjectTrackerLink.find(link.id).destroy!
    assert_forgotten pt, "after destroying the link"

    answered!(pt)
    twist_link!(pt)
    assert_forgotten pt, "after adding a link"
  end

  test "a link that stops being a Twist channel link forgets the access answer" do
    pt = tracker!
    link = twist_link!(pt)
    answered!(pt)
    link.update!(link_type: :other)
    assert_forgotten pt, "after changing the type away"
  end

  test "saving a Twist link without changing it keeps the access answer" do
    pt = tracker!
    link = twist_link!(pt)
    answered!(pt)
    link.update!(name: "Renamed")
    assert_equal false, pt.reload.twist_channel_accessible
    assert_not_nil pt.twist_channel_checked_at
  end

  test "editing a link of another type leaves the access answer alone" do
    pt = with_links!(tracker!)
    twist_link!(pt)
    answered!(pt)
    pt.project_tracker_links.find(&:sow?).update!(url: "https://x/sow-v2")
    assert_equal false, pt.reload.twist_channel_accessible
    assert_not_nil pt.twist_channel_checked_at
  end

  test "adding, editing and removing a link each bust the task cache" do
    pt = tracker!
    Stacks::TaskBuilder.expects(:clear_cache!).once
    link = twist_link!(pt)
    Stacks::TaskBuilder.expects(:clear_cache!).once
    link.update!(url: "https://twist.com/a/133876/ch/11/")
    Stacks::TaskBuilder.expects(:clear_cache!).once
    link.destroy!
  end

  # ---- the Notion project ----------------------------------------------------

  def project_page!(title: "Harvey", stage: "Active")
    NotionPage.create!(
      notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:PROJECTS]),
      page_title: title,
      data: { "last_edited_time" => Time.zone.now.iso8601,
              "properties" => { "Stage" => { "type" => "select", "select" => { "name" => stage } } } }
    )
  end

  test "notion_project_linked? needs a page that still exists, at any stage" do
    pt = tracker!
    assert_not pt.notion_project_linked?

    pt.update_columns(notion_project_id: "")
    assert_not pt.notion_project_linked?

    passed = project_page!(stage: "Passed")
    pt.update_columns(notion_project_id: passed.notion_id)
    assert pt.notion_project_linked?

    passed.destroy
    assert passed.deleted?
    assert_not pt.reload.notion_project_linked?
    assert_equal passed.notion_id, pt.notion_project_id
  end

  test "notion_project wraps the chosen page" do
    page = project_page!(title: "Harvey")
    project = tracker!(notion_project_id: page.notion_id).notion_project
    assert_instance_of Stacks::Notion::Project, project
    assert_equal "Harvey", project.title
    assert_nil tracker!.notion_project
  end

  test "the MCP serializer carries the Twist channel id and the Notion project id" do
    page = project_page!
    pt = tracker!(notion_project_id: page.notion_id)
    twist_link!(pt)
    json = Mcp::ProvisioningSerializers.tracker_json(pt.reload)
    assert_equal 794756, json[:twist_channel_id]
    assert_equal page.notion_id, json[:notion_project_id]

    bare = Mcp::ProvisioningSerializers.tracker_json(tracker!(notion_project_id: ""))
    assert bare.key?(:twist_channel_id)
    assert bare.key?(:notion_project_id)
    assert_nil bare[:twist_channel_id]
    assert_nil bare[:notion_project_id]
  end

  # ---- can the Stacksbot account see the channel? ----------------------------

  def fake_twist(code: 200, body: [{ "id" => 794756 }, { "id" => 11 }])
    stub(get_channels: stub(code: code, parsed_response: body))
  end

  test "sync_twist_channel_access! records, per tracker with a Twist link, whether Stacksbot is in the channel" do
    inside = tracker!
    twist_link!(inside)
    outside = tracker!
    twist_link!(outside, "https://twist.com/a/133876/ch/5/")
    unlinked = with_links!(tracker!)
    now = Time.zone.parse("2026-10-12T09:00:00Z")

    stats = ProjectTracker.sync_twist_channel_access!(twist: fake_twist, now: now)

    assert_equal({ checked: 2, accessible: 1, inaccessible: 1 }, stats)
    assert_equal true, inside.reload.twist_channel_accessible
    assert_equal now, inside.twist_channel_checked_at
    assert_equal false, outside.reload.twist_channel_accessible
    assert_equal now, outside.twist_channel_checked_at
    assert_nil unlinked.reload.twist_channel_accessible
    assert_nil unlinked.twist_channel_checked_at
  end

  test "sync_twist_channel_access! skips completed trackers" do
    done = tracker!
    twist_link!(done)
    done.update_columns(work_completed_at: 1.day.ago)

    stats = ProjectTracker.sync_twist_channel_access!(twist: fake_twist)

    assert_equal({ checked: 0, accessible: 0, inaccessible: 0 }, stats)
    assert_nil done.reload.twist_channel_accessible
    assert_nil done.twist_channel_checked_at
  end

  test "a failed Twist call raises and changes no tracker" do
    pt = tracker!
    twist_link!(pt, "https://twist.com/a/133876/ch/5/")
    checked = Time.zone.parse("2026-10-01T09:00:00Z")
    pt.update_columns(twist_channel_accessible: true, twist_channel_checked_at: checked)

    [
      fake_twist(code: 500, body: []),
      fake_twist(code: 200, body: { "error_code" => 200, "error_string" => "Invalid token" }),
      fake_twist(code: 403, body: { "error_string" => "Forbidden" }),
    ].each do |twist|
      error = assert_raises(Stacks::Twist::Error) { ProjectTracker.sync_twist_channel_access!(twist: twist) }
      assert_match(/channels\/get failed/, error.message)
      assert_equal true, pt.reload.twist_channel_accessible
      assert_equal checked, pt.twist_channel_checked_at
    end
  end

  test "the access answer is written without running the tracker's validations" do
    pt = tracker!
    twist_link!(pt)
    assert_not pt.reload.valid?, "the tracker has no MSA or SOW link"

    ProjectTracker.sync_twist_channel_access!(twist: fake_twist)

    assert_equal true, pt.reload.twist_channel_accessible
  end

  test "sync_twist_channel_access! clears the task cache once, after the answers are written" do
    pt = tracker!
    twist_link!(pt)
    Stacks::TaskBuilder.expects(:clear_cache!).once.with do
      pt.reload.twist_channel_accessible == true
    end

    ProjectTracker.sync_twist_channel_access!(twist: fake_twist)
  end

  test "a failed Twist call does not clear the task cache" do
    Stacks::TaskBuilder.expects(:clear_cache!).never
    assert_raises(Stacks::Twist::Error) do
      ProjectTracker.sync_twist_channel_access!(twist: fake_twist(code: 500, body: []))
    end
  end

  test "get_channels asks Twist for the channels in our workspace" do
    Stacks::Twist.expects(:get).with("/channels/get", has_entry(query: { workspace_id: 133876 })).returns(:response)
    assert_equal :response, Stacks::Twist.new.get_channels
  end

  test "choosing a Notion project busts the task cache; an unrelated save does not" do
    tracker = with_links!(tracker!)
    Stacks::TaskBuilder.expects(:clear_cache!).once
    tracker.update!(notion_project_id: project_page!.notion_id)
    tracker.update!(notes: "Unrelated change")
  end

  test "destroying a tracker still busts the task cache" do
    tracker = with_links!(tracker!)
    Stacks::TaskBuilder.expects(:clear_cache!).at_least_once
    tracker.destroy
  end

  test "a Twist client never prints its token" do
    client = Stacks::Twist.new
    assert_equal "#<Stacks::Twist>", client.inspect
    assert_not_includes client.inspect, "Bearer"
  end

  test "an uppercase host and a zero-padded id are tidied to the one shape" do
    pt = tracker!
    link = pt.project_tracker_links.create!(name: "Twist Channel", link_type: :twist_channel, url: "HTTPS://Twist.com/a/133876/ch/00012")
    assert_equal "https://twist.com/a/133876/ch/12/", link.reload.url
    assert_equal 12, link.twist_channel_id
  end

  test "the Notion project must be a synced Projects page; blank is stored as nil" do
    pt = with_links!(tracker!)
    pt.notion_project_id = "anything-at-all"
    assert_not pt.valid?
    assert_includes pt.errors[:notion_project_id], "must be a page in the Notion Projects database"

    pt.notion_project_id = ""
    assert pt.valid?
    assert_nil pt.notion_project_id
  end

  test "a tracker whose Notion page was removed can still be saved" do
    pt = with_links!(tracker!)
    pt.update_columns(notion_project_id: SecureRandom.uuid)
    assert pt.reload.update(notes: "Still editable")
  end
end
