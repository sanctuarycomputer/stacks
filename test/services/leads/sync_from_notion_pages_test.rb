require "test_helper"

class Leads::SyncFromNotionPagesTest < ActiveSupport::TestCase
  setup do
    @xxix = Studio.create!(name: "XXIX", mini_name: "xxix", studio_type: :client_services)
    # Studio.all_studios memoizes at class level — reset between tests
    Studio.instance_variable_set(:@all_studios, nil)
  end

  teardown do
    Studio.instance_variable_set(:@all_studios, nil)
  end

  def lead_page!(props)
    NotionPage.create!(
      notion_id: SecureRandom.uuid,
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]),
      data: { "properties" => props }
    )
  end

  test "projects lead pages into notion_leads with parsed dates and studio links" do
    page = lead_page!(
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => "2024-03-02" } },
      "Settled Date" => { "type" => "formula", "formula" => { "string" => "2024-04-01" } },
      "✨ Proposal Sent" => { "type" => "date", "date" => { "start" => "2024-03-10" } },
      "✨ Status: Won" => { "type" => "date", "date" => { "start" => "2024-04-01" } },
      "Studio" => { "type" => "multi_select", "multi_select" => [{ "name" => "XXIX" }] }
    )

    Leads::SyncFromNotionPages.call

    lead = NotionLead.find_by!(notion_page_id: page.id)
    assert_equal Date.new(2024, 3, 2), lead.received_at
    assert_equal Date.new(2024, 4, 1), lead.settled_at
    assert_equal Date.new(2024, 3, 10), lead.proposal_sent_at
    assert_equal Date.new(2024, 4, 1), lead.won_at
    assert_equal [@xxix.id], lead.studios.pluck(:id)
  end

  test "unparseable or absent dates become nil without dropping the lead" do
    page = lead_page!(
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => "not a date" } }
    )

    Leads::SyncFromNotionPages.call

    lead = NotionLead.find_by!(notion_page_id: page.id)
    assert_nil lead.received_at
    assert_nil lead.settled_at
  end

  test "rebuild drops leads whose pages were deleted" do
    page = lead_page!({})
    Leads::SyncFromNotionPages.call
    assert_equal 1, NotionLead.count

    page.destroy # acts_as_paranoid soft delete; NotionPage.lead excludes it
    Leads::SyncFromNotionPages.call
    assert_equal 0, NotionLead.count
  end

  test "a DB-level failure on one page does not sink the rest of the rebuild" do
    page_one = lead_page!({})
    page_two = lead_page!(
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => "2024-05-05" } }
    )
    # Feed page_one twice: its second projection hits the real unique index
    # on notion_page_id — a Postgres-level error which, without a per-page
    # savepoint, marks the outer transaction aborted so every later page
    # fails with PG::InFailedSqlTransaction (silently wiping the rebuild).
    NotionPage.stubs(:lead).returns([page_one, page_one, page_two])

    assert_nothing_raised { Leads::SyncFromNotionPages.call }

    assert NotionLead.exists?(notion_page_id: page_one.id)
    assert_equal Date.new(2024, 5, 5),
      NotionLead.find_by!(notion_page_id: page_two.id).received_at
  end

  test "for_studio scopes by join, garden3d sees all" do
    g3d = Studio.create!(name: "garden3d", mini_name: "g3d")
    Studio.instance_variable_set(:@all_studios, nil)
    lead_page!("Studio" => { "type" => "multi_select", "multi_select" => [{ "name" => "XXIX" }] })
    lead_page!({})
    Leads::SyncFromNotionPages.call

    assert_equal 1, NotionLead.for_studio(@xxix).count
    assert_equal 2, NotionLead.for_studio(g3d).count
  end
end
