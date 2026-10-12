require 'test_helper'

# Two tasks about where a project's conversation lives: its Twist channel and
# Notion project are linked, and the Stacksbot account can see the channel.
class StacksTaskBuilderDiscoveriesProjectTrackerSourcesTest < ActiveSupport::TestCase
  DISCOVERY = Stacks::TaskBuilder::Discoveries::ProjectTrackers
  SOURCES = :project_sources_not_linked
  INVITE = :stacksbot_not_in_twist_channel

  def setup
    @admin = AdminUser.create!(email: "admin@sanctuary.computer", password: "passw0rd", roles: ["admin"])
    @lead = AdminUser.create!(email: "lead@sanctuary.computer", password: "passw0rd")
  end

  def discover
    DISCOVERY.new(admin_fallback: [@admin]).tasks
  end

  def tasks_for(pt, type)
    discover.select { |t| t.subject.is_a?(ProjectTracker) && t.subject.id == pt.id && t.type == type }
  end

  # A tracker the discovery treats as in progress. ProjectTracker.in_progress
  # reads snapshot data, so membership is stubbed (one test below checks the
  # real thing).
  def tracker!(in_progress: true, lead: true)
    pt = ProjectTracker.new(name: "Client Project #{SecureRandom.hex(2)}")
    pt.save!(validate: false)
    ProjectLeadPeriod.create!(admin_user: @lead, project_tracker: pt, started_at: Date.today.beginning_of_month) if lead
    @in_progress ||= Set.new
    @in_progress << pt.id if in_progress
    DISCOVERY.any_instance.stubs(:in_progress_ids).returns(@in_progress)
    pt
  end

  def twist_link!(pt, channel = 794756)
    pt.project_tracker_links.create!(name: "Twist Channel", link_type: :twist_channel,
                                     url: "https://twist.com/a/133876/ch/#{channel}/")
  end

  def notion_project!(pt, stage: "Active")
    page = NotionPage.create!(
      notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:PROJECTS]),
      page_title: "Harvey",
      data: { "last_edited_time" => Time.zone.now.iso8601,
              "properties" => { "Stage" => { "type" => "select", "select" => { "name" => stage } } } }
    )
    pt.update_columns(notion_project_id: page.notion_id)
    page
  end

  # ---- project_sources_not_linked -------------------------------------------

  test "an in-progress tracker with neither link raises one task, not two" do
    pt = tracker!
    assert_equal 1, tasks_for(pt, SOURCES).size
  end

  test "one task while either link is missing, none once both are there" do
    twist_only = tracker!
    twist_link!(twist_only)
    notion_only = tracker!
    notion_project!(notion_only)
    both = tracker!
    twist_link!(both)
    notion_project!(both)

    assert_equal 1, tasks_for(twist_only, SOURCES).size
    assert_equal 1, tasks_for(notion_only, SOURCES).size
    assert_empty tasks_for(both, SOURCES)
  end

  test "a blank Notion project id counts as missing" do
    pt = tracker!
    twist_link!(pt)
    pt.update_columns(notion_project_id: "")
    assert_equal 1, tasks_for(pt, SOURCES).size
  end

  test "a Notion project at any stage counts as linked" do
    pt = tracker!
    twist_link!(pt)
    notion_project!(pt, stage: "Passed")
    assert_empty tasks_for(pt, SOURCES)
  end

  test "the task comes back when the Notion page is removed" do
    pt = tracker!
    twist_link!(pt)
    page = notion_project!(pt)
    assert_empty tasks_for(pt, SOURCES)

    page.destroy
    assert page.deleted?
    assert_equal 1, tasks_for(pt, SOURCES).size
  end

  test "not asked of a tracker that is dormant, completed or internal" do
    dormant = tracker!(in_progress: false)
    assert_empty tasks_for(dormant, SOURCES)

    done = tracker!
    done.update_columns(work_completed_at: 1.day.ago)
    assert_empty tasks_for(done, SOURCES)

    internal = tracker!
    assert_equal 1, tasks_for(internal, SOURCES).size
    ProjectTracker.any_instance.stubs(:internal_client?).returns(true)
    assert_empty tasks_for(internal, SOURCES)
  end

  test "the project leads own the linking task, and admins do when there is no lead" do
    led = tracker!
    assert_equal [@lead], tasks_for(led, SOURCES).first.owners

    unled = tracker!(lead: false)
    assert_equal [@admin], tasks_for(unled, SOURCES).first.owners
    # The same fallback the existing no-lead task takes.
    assert_equal [@admin], tasks_for(unled, :no_project_lead_set).first.owners
  end

  # ---- stacksbot_not_in_twist_channel ---------------------------------------

  test "the invite task is raised only when the last check said no" do
    pt = tracker!
    twist_link!(pt)

    assert_nil pt.reload.twist_channel_accessible
    assert_empty tasks_for(pt, INVITE), "not checked yet"

    pt.update_columns(twist_channel_accessible: true)
    assert_empty tasks_for(pt, INVITE), "Stacksbot is in the channel"

    pt.update_columns(twist_channel_accessible: false)
    invite = tasks_for(pt, INVITE)
    assert_equal 1, invite.size
    assert_equal [@admin], invite.first.owners, "admins manage Twist membership, even when there is a lead"
  end

  test "no invite task without a Twist link, whatever the stored answer" do
    pt = tracker!
    pt.update_columns(twist_channel_accessible: false)
    assert_empty tasks_for(pt, INVITE)
  end

  test "the invite task is not asked of a tracker that is dormant, completed or internal" do
    make = lambda do |**opts|
      pt = tracker!(**opts)
      twist_link!(pt)
      pt.update_columns(twist_channel_accessible: false)
      pt
    end

    assert_empty tasks_for(make.call(in_progress: false), INVITE)

    done = make.call
    done.update_columns(work_completed_at: 1.day.ago)
    assert_empty tasks_for(done, INVITE)

    internal = make.call
    assert_equal 1, tasks_for(internal, INVITE).size
    ProjectTracker.any_instance.stubs(:internal_client?).returns(true)
    assert_empty tasks_for(internal, INVITE)
  end

  # ---- labels, links, plumbing ------------------------------------------------

  test "both tasks have a plain label" do
    assert_equal "Project tracker needs its Twist channel and Notion project linked",
                 StacksTask::HUMANIZED_TYPES[:project_sources_not_linked]
    assert_equal "Stacksbot needs inviting to this project's Twist channel",
                 StacksTask::HUMANIZED_TYPES[:stacksbot_not_in_twist_channel]
  end

  test "both tasks point at the tracker's admin page" do
    pt = tracker!
    twist_link!(pt)
    pt.update_columns(twist_channel_accessible: false)
    path = Rails.application.routes.url_helpers.admin_project_tracker_path(pt)

    assert_equal path, tasks_for(pt, SOURCES).first.subject_url
    assert_equal path, tasks_for(pt, INVITE).first.subject_url
    assert_equal path, tasks_for(pt, :no_account_lead_set).first.subject_url
  end

  test "in_progress_ids is the Active tab's trackers" do
    active = ProjectTracker.new(name: "Active")
    active.save!(validate: false)
    dormant = ProjectTracker.new(name: "Dormant")
    dormant.save!(validate: false)
    dormant.update_columns(snapshot: { "last_forecast_assignment_end_date" => 3.months.ago.to_date.iso8601 })

    ids = DISCOVERY.new(admin_fallback: [@admin]).send(:in_progress_ids)

    assert_equal ProjectTracker.in_progress.pluck(:id).to_set, ids
    assert_includes ids, active.id
    assert_not_includes ids, dormant.id
  end

  test "the two tasks add no query per tracker" do
    count = lambda do
      queries = 0
      counter = ->(_name, _start, _finish, _id, payload) do
        queries += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { discover }
      queries
    end
    make = lambda do
      pt = tracker!
      twist_link!(pt)
      notion_project!(pt)
    end

    2.times { make.call }
    at_2 = count.call
    4.times { make.call }
    at_6 = count.call

    assert_equal at_2, at_6, "query count grew with tracker count (#{at_2} at 2, #{at_6} at 6)"
  end
end
