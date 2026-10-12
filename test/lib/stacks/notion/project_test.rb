require 'test_helper'

class StacksNotionProjectTest < ActiveSupport::TestCase
  PROJECTS_PARENT = Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:PROJECTS])
  LEADS_PARENT = Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS])

  def page!(title:, stage:, duplicated: false, edited: Time.zone.now, deleted: false, parent: PROJECTS_PARENT)
    np = NotionPage.create!(
      notion_id: SecureRandom.uuid, notion_parent_type: "database_id", notion_parent_id: parent,
      page_title: title,
      data: { "last_edited_time" => edited.iso8601,
              "properties" => { "Stage" => { "type" => "select", "select" => stage && { "name" => stage } },
                                "🔴 Duplicated" => { "type" => "checkbox", "checkbox" => duplicated } } }
    )
    np.destroy if deleted
    np
  end

  def tracker!(**attrs)
    pt = ProjectTracker.new({ name: "Sources" }.merge(attrs))
    pt.save!(validate: false)
    pt
  end

  test "the Projects database is part of the Notion sync" do
    assert_equal "713b28db4f8a45c68126e9723c65349e", Stacks::Notion::DATABASE_IDS[:PROJECTS]
  end

  test "live? is true for every live stage" do
    stages = ["Active", "Ongoing/Maintenance", "Upcoming/Legal Review", "On Hold", "Paused",
              "Project Capsule Needed", "Introduction", "Pre-proposal Questions Needed",
              "Proposal Needed", "Proposal Sent", "Following Up"]
    assert_equal 11, stages.size
    stages.each do |stage|
      assert page!(title: "P", stage: stage).as_project.live?, "expected #{stage} to be live"
    end
  end

  test "live? is false for a dead stage, no stage, and a project completed long ago" do
    assert_not page!(title: "P", stage: "Passed").as_project.live?
    assert_not page!(title: "P", stage: "Lost/Stale").as_project.live?
    assert_not page!(title: "P", stage: nil).as_project.live?
    assert_not page!(title: "P", stage: "Completed", edited: 91.days.ago).as_project.live?
    assert page!(title: "P", stage: "Completed", edited: 89.days.ago).as_project.live?
  end

  test "live? takes the moment to judge from" do
    done = page!(title: "P", stage: "Completed", edited: Time.zone.parse("2026-01-01T00:00:00Z")).as_project
    assert done.live?(Time.zone.parse("2026-03-01T00:00:00Z"))
    assert_not done.live?(Time.zone.parse("2026-06-01T00:00:00Z"))
  end

  test "a page ticked Duplicated is not live whatever its stage" do
    assert_not page!(title: "P", stage: "Active", duplicated: true).as_project.live?
    assert_not page!(title: "P", stage: "Completed", duplicated: true, edited: 1.day.ago).as_project.live?
  end

  test "label is the title and the stage, or the title alone" do
    assert_equal "Harvey · Active", page!(title: "Harvey", stage: "Active").as_project.label
    assert_equal "Harvey", page!(title: "Harvey", stage: nil).as_project.label
  end

  test "options_for lists live pages only, sorted by label without regard to case" do
    b = page!(title: "beta", stage: "Active")
    a = page!(title: "Alpha", stage: "Proposal Sent")
    c = page!(title: "Charlie", stage: "Paused")
    page!(title: "Gone", stage: "Passed")
    page!(title: "Twin", stage: "Active", duplicated: true)

    assert_equal [["Alpha · Proposal Sent", a.notion_id], ["beta · Active", b.notion_id], ["Charlie · Paused", c.notion_id]],
                 Stacks::Notion::Project.options_for(tracker!)
  end

  test "options_for keeps the tracker's own page when it is no longer live" do
    live = page!(title: "Alpha", stage: "Active")
    passed = page!(title: "Zed", stage: "Passed")
    options = Stacks::Notion::Project.options_for(tracker!(notion_project_id: passed.notion_id))
    assert_equal [["Alpha · Active", live.notion_id], ["Zed · Passed", passed.notion_id]], options
  end

  test "options_for does not repeat the tracker's own page when it is live" do
    live = page!(title: "Alpha", stage: "Active")
    assert_equal [["Alpha · Active", live.notion_id]],
                 Stacks::Notion::Project.options_for(tracker!(notion_project_id: live.notion_id))
  end

  test "options_for marks a page that was removed from Notion" do
    removed = page!(title: "Harvey", stage: "Active", deleted: true)
    assert_equal [["Harvey (removed from Notion)", removed.notion_id]],
                 Stacks::Notion::Project.options_for(tracker!(notion_project_id: removed.notion_id))

    unknown = SecureRandom.uuid
    assert_equal [["Unknown page (removed from Notion)", unknown]],
                 Stacks::Notion::Project.options_for(tracker!(notion_project_id: unknown))
  end

  test "pages from other databases never appear" do
    lead = page!(title: "A Lead", stage: "Active", parent: LEADS_PARENT)
    assert_empty Stacks::Notion::Project.options_for(tracker!)
    assert_not_includes NotionPage.projects.pluck(:notion_id), lead.notion_id
    # Even when a tracker somehow points at it, it is not offered as a project.
    assert_equal [["Unknown page (removed from Notion)", lead.notion_id]],
                 Stacks::Notion::Project.options_for(tracker!(notion_project_id: lead.notion_id))
  end
end
