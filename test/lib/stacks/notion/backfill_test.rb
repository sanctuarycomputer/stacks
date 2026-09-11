require 'test_helper'

class StacksNotionBackfillTest < ActiveSupport::TestCase
  DS = "8ac2bac5-bc47-4674-851e-d1b1e4f779f2"
  DB = "4d9b46b8-bad5-4250-9f14-4347db37964d"
  SEED = "329131fe-a2c7-8071-8aa8-f222b25c76e8"

  setup do
    Stacks::Utils.stubs(:config).returns({ notion: { token: "t" } })
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @client = Stacks::Notion.new
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page(id) = { "object" => "page", "id" => id, "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false, "parent" => { "type" => "workspace", "workspace" => true }, "properties" => {}, "url" => "u" }
  def ds_obj = { "object" => "data_source", "id" => DS, "title" => [{ "plain_text" => "Leads" }], "parent" => { "type" => "database_id", "database_id" => DB }, "properties" => { "Name" => {} }, "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false }
  def feed(results, next_cursor: nil) = { "object" => "list", "results" => results, "next_cursor" => next_cursor, "has_more" => !next_cursor.nil? }

  test "walks the whole feed, fetches schemas for unfetched data sources, walks seeds, and records done" do
    @client.expects(:search).with({ "page_size" => 100, "sort" => { "timestamp" => "last_edited_time", "direction" => "descending" } }).returns(feed([page(SEED), ds_obj], next_cursor: "c2"))
    @client.expects(:search).with({ "page_size" => 100, "sort" => { "timestamp" => "last_edited_time", "direction" => "descending" }, "start_cursor" => "c2" }).returns(feed([page(SecureRandom.uuid)]))
    @client.expects(:get_data_source).with(DS).returns(ds_obj.merge("request_id" => "r"))
    @client.expects(:get_database).with(DB).returns({ "object" => "database", "id" => DB, "title" => [{ "plain_text" => "Leads" }], "data_sources" => [{ "id" => DS, "name" => "Leads" }], "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false })
    @client.expects(:get_block_children).with(SEED, start_cursor: nil, page_size: 100).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })

    stats = Stacks::Notion::Backfill.new(@client, seed_ids: [SEED.delete("-")]).run

    assert_equal 2, stats[:pages]
    assert_equal 1, stats[:schemas]
    assert_equal 1, stats[:seeds]
    assert NotionDataSource.find_by!(notion_id: DS).fetched_at.present?
    assert NotionDatabase.exists?(notion_id: DB)
    assert_equal "done", SourceSync.for(:notion_backfill).reload.cursor["phase"]
  end

  test "resumes the feed from the stored cursor and skips fetched schemas" do
    SourceSync.for(:notion_backfill).advance!(cursor: { "phase" => "feed", "next_cursor" => "c9" })
    NotionDataSource.create!(notion_id: DS, database_id: DB, title: "Leads", data: {}, fetched_at: Time.current)
    NotionDatabase.create!(notion_id: DB, title: "Leads", data: {})
    @client.expects(:search).with { |body| body["start_cursor"] == "c9" }.returns(feed([]))
    @client.expects(:get_data_source).never
    Stacks::Notion::Backfill.new(@client, seed_ids: []).run
    assert_equal "done", SourceSync.for(:notion_backfill).reload.cursor["phase"]
  end

  test "a failure mid-feed keeps the cursor for resume" do
    @client.stubs(:search).returns(feed([page(SecureRandom.uuid)], next_cursor: "c2")).then.raises(Stacks::Notion::RequestError.new(502, {}))
    assert_raises(Stacks::Notion::RequestError) { Stacks::Notion::Backfill.new(@client, seed_ids: []).run }
    assert_equal({ "phase" => "feed", "next_cursor" => "c2" }, SourceSync.for(:notion_backfill).reload.cursor)
  end
end
