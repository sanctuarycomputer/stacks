require 'test_helper'

class StacksNotionSyncDatabaseTest < ActiveSupport::TestCase
  LEADS_DB = Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS])
  DS = "8ac2bac5-bc47-4674-851e-d1b1e4f779f2"

  setup do
    Stacks::Utils.stubs(:config).returns({ notion: { token: "t" } })
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
  end

  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def row(id, title, last_edited: "2026-09-01T00:00:00.000Z", in_trash: false)
    { "object" => "page", "id" => id, "last_edited_time" => last_edited, "in_trash" => in_trash,
      "parent" => { "type" => "data_source_id", "data_source_id" => DS, "database_id" => LEADS_DB },
      "properties" => { "Name" => { "type" => "title", "title" => [{ "plain_text" => title }] } }, "url" => "u" }
  end

  test "upserts every row across pages and soft-deletes rows missing from the query" do
    gone = NotionPage.create!(notion_id: SecureRandom.uuid, database_id: LEADS_DB, data: {}, page_title: "gone")
    other_db = NotionPage.create!(notion_id: SecureRandom.uuid, database_id: SecureRandom.uuid, data: {}, page_title: "other")
    client = Stacks::Notion.new
    client.stubs(:get_database).with(Stacks::Notion::DATABASE_IDS[:LEADS]).returns({ "data_sources" => [{ "id" => DS }] })
    client.stubs(:query_data_source).with(DS, {}).returns({ "results" => [row("a" * 32, "A")], "next_cursor" => "c2", "has_more" => true })
    client.stubs(:query_data_source).with(DS, { start_cursor: "c2" }).returns({ "results" => [row("b" * 32, "B")], "next_cursor" => nil, "has_more" => false })

    stats = client.sync_database(Stacks::Notion::DATABASE_IDS[:LEADS])

    assert_equal({ upserted: 2, removed: 1 }, stats)
    assert_equal %w[A B].sort, NotionPage.lead.pluck(:page_title).sort
    assert NotionPage.with_deleted.find(gone.id).deleted?
    refute NotionPage.find(other_db.id).deleted?
  end

  test "a row that comes back after being soft-deleted is recovered" do
    id = Stacks::Notion::Ids.normalize("c" * 32)
    NotionPage.create!(notion_id: id, database_id: LEADS_DB, data: {}, page_title: "C").destroy
    client = Stacks::Notion.new
    client.stubs(:get_database).returns({ "data_sources" => [{ "id" => DS }] })
    client.stubs(:query_data_source).returns({ "results" => [row("c" * 32, "C")], "next_cursor" => nil })
    client.sync_database(Stacks::Notion::DATABASE_IDS[:LEADS])
    refute NotionPage.find_by!(notion_id: id).deleted?
  end
end
