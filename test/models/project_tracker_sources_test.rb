require 'test_helper'

# A tracker names where its conversation lives: one or many Twist channel
# links, each in one stored shape, and one or many Notion Projects pages.
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
    assert_equal [794756], pt.reload.twist_channel_ids
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

  # ---- one or many per tracker ----------------------------------------------

  SAME_CHANNEL_ERROR = "This Twist channel is already linked to this project.".freeze

  test "a tracker may have two different Twist channels, and twist_channel_ids returns both sorted" do
    pt = with_links!(tracker!)
    twist_link!(pt)
    twist_link(pt, "https://twist.com/a/133876/ch/11/")
    assert pt.valid?, pt.errors.full_messages.to_sentence
    pt.save!
    assert_equal [11, 794756], pt.reload.twist_channel_ids
  end

  test "the same Twist channel twice on one tracker is refused" do
    pt = with_links!(tracker!)
    twist_link!(pt)
    twist_link(pt, CHANNEL)
    assert_not pt.valid?
    assert_equal [SAME_CHANNEL_ERROR], pt.errors[:base]
  end

  test "the same channel pasted in another shape is still the same channel" do
    pt = with_links!(tracker!)
    twist_link!(pt)
    # Not tidied yet: the tracker is checked before its links are.
    twist_link(pt, "  https://twist.com/a/133876/ch/794756/t/6877281  ")
    assert_not pt.valid?
    assert_includes pt.errors[:base], SAME_CHANNEL_ERROR
  end

  test "a malformed Twist link is refused for its shape, not as a repeat" do
    pt = with_links!(tracker!)
    twist_link(pt, "https://twist.com/a/1/ch/2/")
    twist_link(pt, "https://twist.com/a/1/ch/2/")
    assert_not pt.valid?
    assert_empty pt.errors[:base]
    assert_includes pt.errors.full_messages.join, "must be a Twist channel in our workspace"
  end

  test "replacing a Twist channel link in one save works" do
    pt = with_links!(tracker!)
    old = twist_link!(pt)
    pt.reload.update!(project_tracker_links_attributes: [
      { id: old.id, _destroy: "1" },
      { name: "Twist Channel", link_type: "twist_channel", url: "https://twist.com/a/133876/ch/11/" },
    ])
    links = pt.reload.project_tracker_links.select(&:twist_channel?)
    assert_equal ["https://twist.com/a/133876/ch/11/"], links.map(&:url)
    assert_equal [11], pt.twist_channel_ids
  end

  test "removing a channel's link and adding the same channel back in one save works" do
    pt = with_links!(tracker!)
    old = twist_link!(pt)
    pt.reload.update!(project_tracker_links_attributes: [
      { id: old.id, _destroy: "1" },
      { name: "Twist Channel", link_type: "twist_channel", url: CHANNEL },
    ])
    assert_equal [794756], pt.reload.twist_channel_ids
    assert_equal 1, pt.project_tracker_links.count(&:twist_channel?)
  end

  test "twist_channel_ids is empty with no Twist link" do
    assert_equal [], with_links!(tracker!).twist_channel_ids
  end

  test "there is no singular twist_channel_id on a tracker any more" do
    assert_not tracker!.respond_to?(:twist_channel_id)
  end

  # ---- the stored access answer follows the link -----------------------------

  def answered!(pt)
    pt.update_columns(twist_channels_inaccessible: [794756], twist_channel_checked_at: Time.zone.now)
  end

  def assert_forgotten(pt, message)
    pt.reload
    assert_equal [], pt.twist_channels_inaccessible, message
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

    answered!(pt)
    twist_link!(pt, "https://twist.com/a/133876/ch/12/")
    assert_forgotten pt, "after adding a second channel"
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
    assert_equal [794756], pt.reload.twist_channels_inaccessible
    assert_not_nil pt.twist_channel_checked_at
  end

  test "editing a link of another type leaves the access answer alone" do
    pt = with_links!(tracker!)
    twist_link!(pt)
    answered!(pt)
    pt.project_tracker_links.find(&:sow?).update!(url: "https://x/sow-v2")
    assert_equal [794756], pt.reload.twist_channels_inaccessible
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

  # The column the code before this one wrote. ProjectTracker ignores it, so
  # it can only be set in SQL.
  def set_legacy_columns!(pt, notion_project_id: nil, twist_channel_accessible: nil)
    ProjectTracker.connection.exec_update(
      "UPDATE project_trackers SET notion_project_id = $1, twist_channel_accessible = $2 WHERE id = $3", "SQL",
      [notion_project_id, twist_channel_accessible, pt.id]
    )
  end

  test "two Notion projects are stored, in the order they were chosen" do
    a = project_page!(title: "Harvey")
    b = project_page!(title: "Harvey Retainer")
    pt = with_links!(tracker!)
    pt.update!(notion_project_ids: [b.notion_id, a.notion_id])
    assert_equal [b.notion_id, a.notion_id], pt.reload.notion_project_ids
  end

  test "a new tracker has no Notion projects" do
    assert_equal [], ProjectTracker.new.notion_project_ids
    assert_equal [], tracker!.reload.notion_project_ids
  end

  test "blank and repeated Notion project ids are cleaned before saving" do
    page = project_page!
    pt = with_links!(tracker!)
    # A multiple select posts a hidden blank first.
    pt.update!(notion_project_ids: ["", " #{page.notion_id} ", page.notion_id, nil])
    assert_equal [page.notion_id], pt.reload.notion_project_ids

    pt.update!(notion_project_ids: [""])
    assert_equal [], pt.reload.notion_project_ids

    pt.notion_project_ids = nil
    assert pt.valid?, pt.errors.full_messages.to_sentence
    assert_equal [], pt.notion_project_ids
  end

  test "an id that is not a synced Projects page is refused when it is added" do
    page = project_page!
    pt = with_links!(tracker!)
    pt.notion_project_ids = [page.notion_id, "anything-at-all"]
    assert_not pt.valid?
    assert_equal ["must be pages in the Notion Projects database"], pt.errors[:notion_project_ids]

    pt.notion_project_ids = [page.notion_id]
    assert pt.valid?, pt.errors.full_messages.to_sentence
  end

  test "a page from another Notion database is refused" do
    lead = NotionPage.create!(
      notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]),
      page_title: "A Lead", data: {}
    )
    pt = with_links!(tracker!)
    pt.notion_project_ids = [lead.notion_id]
    assert_not pt.valid?
    assert_includes pt.errors[:notion_project_ids], "must be pages in the Notion Projects database"
  end

  test "an id stored before the change is not checked again, so a removed page does not block saving" do
    gone = SecureRandom.uuid
    pt = with_links!(tracker!)
    pt.update_columns(notion_project_ids: [gone])
    pt.reload
    assert pt.update(notes: "Still editable")

    # Adding a real page beside it is fine; the removed one stays.
    page = project_page!
    assert pt.update(notion_project_ids: [gone, page.notion_id]), pt.errors.full_messages.to_sentence
    assert_equal [gone, page.notion_id], pt.reload.notion_project_ids

    # Taking it off and putting it back is adding it.
    pt.update!(notion_project_ids: [page.notion_id])
    assert_not pt.update(notion_project_ids: [page.notion_id, gone])
    assert_includes pt.errors[:notion_project_ids], "must be pages in the Notion Projects database"
  end

  test "notion_projects returns only the pages that still exist, in one query" do
    a = project_page!(title: "Harvey")
    b = project_page!(title: "Harvey Retainer", stage: "Passed")
    removed = project_page!(title: "Gone")
    pt = tracker!
    pt.update_columns(notion_project_ids: [b.notion_id, removed.notion_id, SecureRandom.uuid, a.notion_id])
    removed.destroy
    assert removed.deleted?

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/ }
    projects = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { pt.notion_projects }

    assert_equal 1, queries
    assert(projects.all? { |p| p.is_a?(Stacks::Notion::Project) })
    assert_equal ["Harvey Retainer", "Harvey"], projects.map(&:title)
    assert_equal [], tracker!.notion_projects
    assert_not tracker!.respond_to?(:notion_project)
  end

  test "notion_project_linked? needs at least one page that still exists, at any stage" do
    pt = tracker!
    assert_not pt.notion_project_linked?

    passed = project_page!(stage: "Passed")
    pt.update_columns(notion_project_ids: [SecureRandom.uuid, passed.notion_id])
    assert pt.notion_project_linked?

    passed.destroy
    assert passed.deleted?
    assert_not pt.reload.notion_project_linked?
    assert_includes pt.notion_project_ids, passed.notion_id
  end

  test "the MCP serializer carries the Twist channel ids and the Notion project ids, and neither singular key" do
    a = project_page!
    b = project_page!(title: "Harvey Retainer")
    pt = tracker!(notion_project_ids: [a.notion_id, b.notion_id])
    twist_link!(pt)
    twist_link!(pt, "https://twist.com/a/133876/ch/11/")
    json = Mcp::ProvisioningSerializers.tracker_json(pt.reload)
    assert_equal [11, 794756], json[:twist_channel_ids]
    assert_equal [a.notion_id, b.notion_id], json[:notion_project_ids]
    assert_not json.key?(:twist_channel_id)
    assert_not json.key?(:notion_project_id)

    bare = Mcp::ProvisioningSerializers.tracker_json(tracker!)
    assert_equal [], bare[:twist_channel_ids]
    assert_equal [], bare[:notion_project_ids]
  end

  # ---- the columns this replaced ---------------------------------------------

  test "the two superseded columns are still in the table but not on the model" do
    columns = ProjectTracker.connection.columns(:project_trackers).map(&:name)
    assert_includes columns, "notion_project_id"
    assert_includes columns, "twist_channel_accessible"
    assert_not_includes ProjectTracker.column_names, "notion_project_id"
    assert_not_includes ProjectTracker.column_names, "twist_channel_accessible"
    assert_not tracker!.respond_to?(:notion_project_id)
    assert_not tracker!.respond_to?(:twist_channel_accessible)
  end

  test "what the old code left in the superseded columns changes nothing" do
    page = project_page!
    pt = with_links!(tracker!)
    twist_link!(pt)
    set_legacy_columns!(pt, notion_project_id: page.notion_id, twist_channel_accessible: false)
    pt.reload
    assert_equal [], pt.notion_project_ids
    assert_not pt.notion_project_linked?
    assert_equal [], pt.twist_channels_inaccessible
    assert pt.update(notes: "Saves without touching them")
    row = ProjectTracker.connection.select_one("SELECT notion_project_id, twist_channel_accessible FROM project_trackers WHERE id = #{pt.id}")
    assert_equal page.notion_id, row["notion_project_id"]
    assert_equal false, row["twist_channel_accessible"]
  end

  test "no code reads or writes the two superseded columns" do
    allowed = lambda do |path, line, number, lines|
      next true if path == "app/models/project_tracker.rb" && line.include?("ignored_columns")
      next false unless path == "lib/tasks/stacks.rake"
      # Only inside the backfill task.
      first = lines.index { |l| l.include?("task :backfill_notion_project_ids") }
      last = first && (first...lines.size).find { |i| lines[i] == "  end" }
      first && last && number.between?(first, last)
    end
    hits = Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,rake,erb,arb,haml,jbuilder}")).sort.flat_map do |file|
      path = Pathname.new(file).relative_path_from(Rails.root).to_s
      lines = File.read(file).split("\n")
      lines.each_with_index.filter_map do |line, number|
        next unless line =~ /\bnotion_project_id\b|twist_channel_accessible|at_most_one_twist/
        "#{path}:#{number + 1}: #{line.strip}" unless allowed.call(path, line, number, lines)
      end
    end
    assert_empty hits, "the superseded columns are still used:\n#{hits.join("\n")}"
  end

  # ---- can the Stacksbot account see the channel? ----------------------------

  def fake_twist(code: 200, body: [{ "id" => 794756 }, { "id" => 11 }])
    stub(get_channels: stub(code: code, parsed_response: body))
  end

  test "sync_twist_channel_access! records, per tracker with a Twist link, the channels Stacksbot is not in" do
    inside = tracker!
    twist_link!(inside)
    outside = tracker!
    twist_link!(outside, "https://twist.com/a/133876/ch/5/")
    unlinked = with_links!(tracker!)
    now = Time.zone.parse("2026-10-12T09:00:00Z")

    stats = ProjectTracker.sync_twist_channel_access!(twist: fake_twist, now: now)

    assert_equal({ checked: 2, accessible: 1, inaccessible: 1 }, stats)
    assert_equal [], inside.reload.twist_channels_inaccessible
    assert_equal now, inside.twist_channel_checked_at
    assert_equal [5], outside.reload.twist_channels_inaccessible
    assert_equal now, outside.twist_channel_checked_at
    assert_equal [], unlinked.reload.twist_channels_inaccessible
    assert_nil unlinked.twist_channel_checked_at
  end

  test "access is per channel: with two channels and Stacksbot in one, only the other is stored" do
    pt = tracker!
    twist_link!(pt)
    twist_link!(pt, "https://twist.com/a/133876/ch/5/")
    twist_link!(pt, "https://twist.com/a/133876/ch/3/")

    stats = ProjectTracker.sync_twist_channel_access!(twist: fake_twist)

    # Trackers checked, then channels.
    assert_equal({ checked: 1, accessible: 1, inaccessible: 2 }, stats)
    assert_equal [3, 5], pt.reload.twist_channels_inaccessible
    assert_not_nil pt.twist_channel_checked_at
  end

  test "once Stacksbot is in every channel the stored list is emptied" do
    pt = tracker!
    twist_link!(pt)
    twist_link!(pt, "https://twist.com/a/133876/ch/11/")
    pt.update_columns(twist_channels_inaccessible: [11], twist_channel_checked_at: 1.day.ago)

    stats = ProjectTracker.sync_twist_channel_access!(twist: fake_twist)

    assert_equal({ checked: 1, accessible: 2, inaccessible: 0 }, stats)
    assert_equal [], pt.reload.twist_channels_inaccessible
  end

  test "sync_twist_channel_access! skips completed trackers" do
    done = tracker!
    twist_link!(done, "https://twist.com/a/133876/ch/5/")
    done.update_columns(work_completed_at: 1.day.ago)

    stats = ProjectTracker.sync_twist_channel_access!(twist: fake_twist)

    assert_equal({ checked: 0, accessible: 0, inaccessible: 0 }, stats)
    assert_equal [], done.reload.twist_channels_inaccessible
    assert_nil done.twist_channel_checked_at
  end

  test "a failed Twist call raises and changes no tracker" do
    pt = tracker!
    twist_link!(pt, "https://twist.com/a/133876/ch/5/")
    checked = Time.zone.parse("2026-10-01T09:00:00Z")
    pt.update_columns(twist_channels_inaccessible: [], twist_channel_checked_at: checked)

    [
      fake_twist(code: 500, body: []),
      fake_twist(code: 200, body: { "error_code" => 200, "error_string" => "Invalid token" }),
      fake_twist(code: 403, body: { "error_string" => "Forbidden" }),
    ].each do |twist|
      error = assert_raises(Stacks::Twist::Error) { ProjectTracker.sync_twist_channel_access!(twist: twist) }
      assert_match(/channels\/get failed/, error.message)
      assert_equal [], pt.reload.twist_channels_inaccessible
      assert_equal checked, pt.twist_channel_checked_at
    end
  end

  test "the access answer is written without running the tracker's validations" do
    pt = tracker!
    twist_link!(pt)
    assert_not pt.reload.valid?, "the tracker has no MSA or SOW link"

    ProjectTracker.sync_twist_channel_access!(twist: fake_twist)

    assert_not_nil pt.reload.twist_channel_checked_at
  end

  test "sync_twist_channel_access! clears the task cache once, after the answers are written" do
    pt = tracker!
    twist_link!(pt)
    Stacks::TaskBuilder.expects(:clear_cache!).once.with do
      pt.reload.twist_channel_checked_at.present?
    end

    ProjectTracker.sync_twist_channel_access!(twist: fake_twist)
  end

  test "a failed Twist call does not clear the task cache" do
    Stacks::TaskBuilder.expects(:clear_cache!).never
    assert_raises(Stacks::Twist::Error) do
      ProjectTracker.sync_twist_channel_access!(twist: fake_twist(code: 500, body: []))
    end
  end

  # ---- the channel's real name ----------------------------------------------

  def named_twist(*channels)
    fake_twist(body: channels.map { |id, name| { "id" => id, "name" => name } })
  end

  def link_updates
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql] =~ /\AUPDATE "project_tracker_links"/ }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "the sync gives a link still named Twist Channel the channel's real name" do
    pt = tracker!
    link = twist_link!(pt)

    ProjectTracker.sync_twist_channel_access!(twist: named_twist([794756, "Harvey Client"]))

    assert_equal "Harvey Client", link.reload.name
  end

  test "the sync names a link whose name is blank" do
    pt = tracker!
    link = twist_link!(pt)
    # The model refuses a blank name; a row written around it still gets one.
    link.update_columns(name: "")

    ProjectTracker.sync_twist_channel_access!(twist: named_twist([794756, "Harvey Client"]))

    assert_equal "Harvey Client", link.reload.name
  end

  test "the sync never replaces a name a person typed" do
    pt = tracker!
    link = twist_link!(pt)
    link.update_columns(name: "Where the client talks")

    assert_equal 0, link_updates { ProjectTracker.sync_twist_channel_access!(twist: named_twist([794756, "Harvey Client"])) }

    assert_equal "Where the client talks", link.reload.name
  end

  test "naming a link does not forget the access answer the same sync has just written" do
    pt = tracker!
    twist_link!(pt)
    twist_link!(pt, "https://twist.com/a/133876/ch/5/")
    now = Time.zone.parse("2026-10-12T09:00:00Z")

    ProjectTracker.sync_twist_channel_access!(twist: named_twist([794756, "Harvey Client"]), now: now)

    assert_equal [5], pt.reload.twist_channels_inaccessible
    assert_equal now, pt.twist_channel_checked_at
    assert_equal ["Harvey Client", "Twist Channel"], pt.project_tracker_links.sort_by { |l| -l.twist_channel_id }.map(&:name)
  end

  test "the sync writes no link whose name is already right, or whose channel Twist does not name" do
    pt = tracker!
    link = twist_link!(pt)
    twist = named_twist([794756, "Harvey Client"])
    assert_equal 1, link_updates { ProjectTracker.sync_twist_channel_access!(twist: twist) }
    before = link.reload.updated_at

    assert_equal 0, link_updates { ProjectTracker.sync_twist_channel_access!(twist: twist) }
    assert_equal before, link.reload.updated_at

    # A channel that comes back with no name, or the placeholder itself, changes nothing.
    link.update_columns(name: "Twist Channel")
    [fake_twist, named_twist([794756, " "]), named_twist([794756, "Twist Channel"])].each do |unnamed|
      assert_equal 0, link_updates { ProjectTracker.sync_twist_channel_access!(twist: unnamed) }
    end
    assert_equal "Twist Channel", link.reload.name
  end

  test "the sync leaves a completed tracker's link name alone" do
    done = tracker!
    link = twist_link!(done)
    done.update_columns(work_completed_at: 1.day.ago)

    ProjectTracker.sync_twist_channel_access!(twist: named_twist([794756, "Harvey Client"]))

    assert_equal "Twist Channel", link.reload.name
  end

  test "get_channels asks Twist for the channels in our workspace" do
    Stacks::Twist.expects(:get).with("/channels/get", has_entry(query: { workspace_id: 133876 })).returns(:response)
    assert_equal :response, Stacks::Twist.new.get_channels
  end

  test "choosing a Notion project busts the task cache; an unrelated save does not" do
    tracker = with_links!(tracker!)
    first = project_page!
    second = project_page!(title: "Harvey Retainer")
    Stacks::TaskBuilder.expects(:clear_cache!).twice
    tracker.update!(notion_project_ids: [first.notion_id])
    tracker.update!(notion_project_ids: [first.notion_id, second.notion_id])
    tracker.update!(notes: "Unrelated change")
    tracker.update!(notion_project_ids: ["", first.notion_id, second.notion_id])
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
end
