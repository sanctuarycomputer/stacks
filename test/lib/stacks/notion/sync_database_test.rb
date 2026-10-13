require 'test_helper'

# The nightly whole-database sync deletes every row under the database it
# read that it did not see. These pin what it does to the database it reads
# and that it leaves Stacksbot's Observations and Problems alone. No network:
# query_database is stubbed on a client built without its token.
class StacksNotionSyncDatabaseTest < ActiveSupport::TestCase
  include NotionLogFixtures

  LEADS = Stacks::Notion::DATABASE_IDS[:LEADS]
  LEADS_PARENT = Stacks::Utils.dashify_uuid(LEADS)

  def lead_row(id: SecureRandom.uuid, title: "New lead")
    { "object" => "page", "id" => id,
      "icon" => { "type" => "file", "file" => { "url" => "https://s3.test/icon?expires=1" } },
      "cover" => { "type" => "file", "file" => { "url" => "https://s3.test/cover?expires=1" } },
      "parent" => { "type" => "database_id", "database_id" => LEADS_PARENT },
      "properties" => {
        "Name" => { "type" => "title", "title" => [{ "plain_text" => title }, { "plain_text" => " (more)" }] },
        "Docs" => { "type" => "files", "files" => [{ "name" => "a.pdf", "type" => "file", "file" => { "url" => "https://s3.test/a?expires=1" } }] },
      } }
  end

  setup do
    @client = Stacks::Notion.allocate
    @observation = observation!(project_ids: %w[p1])
    @problem = problem!(project_ids: %w[p1])
    @unfiled_problem = problem!(project_ids: [])
    @stale_lead = NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                                     notion_parent_id: LEADS_PARENT, page_title: "Stale", data: {})
  end

  test "a whole-database sync stores what it saw, deletes the rest of that database and nothing else" do
    row = lead_row
    @client.expects(:query_database).once.with(LEADS, nil).returns({ "results" => [row], "next_cursor" => nil })
    @client.sync_database(LEADS)

    assert NotionPage.with_deleted.find(@stale_lead.id).deleted?, "a lead the sync did not see is soft-deleted"
    [@observation, @problem, @unfiled_problem].each do |kept|
      assert_nil NotionPage.with_deleted.find(kept.id).deleted_at, "#{kept.page_title} is not the sync's to delete"
    end
    assert_equal 1, NotionPage.observations.count
    assert_equal 2, NotionPage.problems.count

    stored = NotionPage.find_by!(notion_id: row["id"])
    assert_equal "New lead", stored.page_title
    assert_equal "database_id", stored.notion_parent_type
    assert_equal LEADS_PARENT, stored.notion_parent_id
    assert_not stored.data.key?("icon")
    assert_not stored.data.key?("cover")
    assert_equal [{ "name" => "a.pdf", "type" => "file" }], stored.data.dig("properties", "Docs", "files")
    assert_equal [stored.id], NotionPage.lead.pluck(:id)
  end

  test "a whole-database sync that sees nothing deletes nothing" do
    @client.expects(:query_database).once.returns({ "results" => [], "next_cursor" => nil })
    @client.sync_database(LEADS)
    assert_nil @stale_lead.reload.deleted_at
    assert_equal 3, NotionPage.observations.count + NotionPage.problems.count
  end

  test "the daily task hands the whole-database sync no filtered database" do
    filtered = Stacks::Notion::FILTERED_DATABASES.values.map { |d| d[:id] }
    assert_empty Stacks::Notion::DATABASE_IDS.values.map { |id| id.delete("-") } & filtered
  end

  # The guard compared raw strings, so any other spelling of the id got through.
  test "a filtered database is refused in every spelling of its id" do
    @client.expects(:query_database).never
    Stacks::Notion::FILTERED_DATABASES.each_value do |config|
      id = config[:id]
      [id, id.upcase, Stacks::Utils.dashify_uuid(id), Stacks::Utils.dashify_uuid(id).upcase, " #{id}\n", "\t#{Stacks::Utils.dashify_uuid(id)} "].each do |spelling|
        assert_raises(ArgumentError, spelling.inspect) { @client.sync_database(spelling) }
      end
    end
    assert_equal 3, NotionPage.observations.count + NotionPage.problems.count
  end

  # The sweep is keyed on the first result's parent. An answer that is not
  # from the database asked for must not choose what is swept.
  test "a response whose first result is under another database sweeps nothing" do
    row = lead_row
    row["parent"] = { "type" => "database_id", "database_id" => Stacks::Notion.filtered_parent_id(:OBSERVATIONS) }
    @client.expects(:query_database).once.with(LEADS, nil).returns({ "results" => [row], "next_cursor" => nil })
    Rails.logger.expects(:warn).with(regexp_matches(/sync_database.*#{LEADS}.*skipped/m)).once
    @client.sync_database(LEADS)
    assert_nil NotionPage.with_deleted.find(@observation.id).deleted_at, "a stored observation is not swept"
    assert_nil NotionPage.with_deleted.find(@stale_lead.id).deleted_at
  end

  test "the sweep still runs when the database is asked for by its dashed id" do
    @client.expects(:query_database).once.returns({ "results" => [lead_row], "next_cursor" => nil })
    @client.sync_database(LEADS_PARENT.upcase)
    assert NotionPage.with_deleted.find(@stale_lead.id).deleted?
  end
end
