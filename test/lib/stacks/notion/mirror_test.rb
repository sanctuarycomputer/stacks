require 'test_helper'

class StacksNotionMirrorTest < ActiveSupport::TestCase
  M = Stacks::Notion::Mirror
  PAGE_ID = "3d6131fe-a2c7-8068-ac6e-d49df344d405"
  DS_ID   = "e5d5d0da-a85e-4b3f-b900-9fd06a315622"
  DB_ID   = "438196be-db11-412e-b8e7-37bc1bd75b2b"

  def page_obj(last_edited: "2026-09-10T21:55:00.000Z", in_trash: false, request_id: "req-1", title_runs: ["In 2024, ", "xxix.co Better"])
    {
      "object" => "page", "id" => PAGE_ID, "created_time" => "2026-09-01T00:00:00.000Z",
      "last_edited_time" => last_edited, "in_trash" => in_trash, "is_archived" => false, "is_locked" => false,
      "parent" => { "type" => "data_source_id", "data_source_id" => DS_ID, "database_id" => DB_ID },
      "properties" => { "Name" => { "id" => "title", "type" => "title", "title" => title_runs.map { |t| { "plain_text" => t } } } },
      "url" => "https://www.notion.so/x-#{PAGE_ID.delete('-')}", "public_url" => nil,
      "request_id" => request_id
    }.compact
  end

  test "upsert_page stores the raw object minus request_id and fills the lookup columns" do
    page = M.upsert_page(page_obj, fetched_at: Time.zone.parse("2026-09-10T22:00:00Z"))
    assert_equal PAGE_ID, page.notion_id
    assert_equal DB_ID, page.database_id
    assert_equal DS_ID, page.data_source_id
    assert_equal "data_source_id", page.notion_parent_type
    assert_equal DS_ID, page.notion_parent_id
    assert_equal Time.zone.parse("2026-09-10T21:55:00Z"), page.notion_last_edited_at
    assert_equal "In 2024, xxix.co Better", page.page_title
    assert_equal "https://www.notion.so/x-#{PAGE_ID.delete('-')}", page.url
    refute page.data.key?("request_id")
    assert_equal Time.zone.parse("2026-09-10T22:00:00Z"), page.page_fetched_at
    refute page.in_trash
  end

  test "a search-result object (no request_id) and a GET object land on the same row" do
    a = M.upsert_page(page_obj(request_id: nil))
    b = M.upsert_page(page_obj(request_id: "req-9"))
    assert_equal a.id, b.id
    assert_equal 1, NotionPage.with_deleted.where(notion_id: PAGE_ID).count
    assert_equal a.data, b.reload.data
  end

  test "an older last_edited_time never moves the row backwards" do
    M.upsert_page(page_obj(last_edited: "2026-09-10T21:55:00.000Z"))
    page = M.upsert_page(page_obj(last_edited: "2026-09-10T21:50:00.000Z", title_runs: ["old"]))
    assert_equal "In 2024, xxix.co Better", page.page_title
    assert_equal Time.zone.parse("2026-09-10T21:55:00Z"), page.notion_last_edited_at
  end

  test "a soft-deleted row is found with_deleted and recovered only when in_trash is false" do
    M.upsert_page(page_obj).destroy
    trashed = M.upsert_page(page_obj(in_trash: true, last_edited: "2026-09-10T22:00:00.000Z"))
    assert trashed.deleted?
    assert trashed.in_trash
    live = M.upsert_page(page_obj(in_trash: false, last_edited: "2026-09-10T22:05:00.000Z"))
    refute live.deleted?
    refute live.in_trash
  end

  test "a newer stamp marks a walked tree stale" do
    page = M.upsert_page(page_obj)
    page.update!(tree_fetched_for_edited_at: page.notion_last_edited_at)
    M.upsert_page(page_obj(last_edited: "2026-09-10T22:10:00.000Z"))
    assert page.reload.blocks_stale_at.present?
    # same stamp again: not re-flagged after it was cleared
    page.update!(blocks_stale_at: nil, tree_fetched_for_edited_at: Time.zone.parse("2026-09-10T22:10:00Z"))
    M.upsert_page(page_obj(last_edited: "2026-09-10T22:10:00.000Z"))
    assert_nil page.reload.blocks_stale_at
  end

  test "title_of handles plain pages, missing titles, and nil runs" do
    assert_equal "Guide", M.title_of("properties" => { "title" => { "type" => "title", "title" => [{ "plain_text" => "Guide" }] } })
    assert_equal "", M.title_of("properties" => {})
    assert_equal "", M.title_of({})
    assert_equal "DS", M.title_of("object" => "data_source", "title" => [{ "plain_text" => "DS" }])
  end

  test "upsert_data_source and upsert_database" do
    ds = M.upsert_data_source({ "object" => "data_source", "id" => DS_ID, "title" => [{ "plain_text" => "Tasks" }],
                                "parent" => { "type" => "database_id", "database_id" => DB_ID },
                                "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false, "properties" => {}, "request_id" => "r" })
    assert_equal DB_ID, ds.database_id
    assert_equal "Tasks", ds.title
    refute ds.data.key?("request_id")
    db = M.upsert_database({ "object" => "database", "id" => DB_ID, "title" => [{ "plain_text" => "Tasks" }],
                             "data_sources" => [{ "id" => DS_ID, "name" => "Tasks" }], "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false })
    assert_equal "Tasks", db.title
    assert_equal DS_ID, db.data.dig("data_sources", 0, "id")
  end

  def block(id, parent, has_children: false)
    { "object" => "block", "id" => id, "type" => "paragraph", "has_children" => has_children,
      "parent" => { "type" => "page_id", "page_id" => parent }, "paragraph" => { "rich_text" => [] } }
  end

  test "replace_level replaces rows, updates moved blocks in place, and stamps the marker" do
    page = M.upsert_page(page_obj)
    M.replace_level(parent_id: PAGE_ID, page_id: PAGE_ID, blocks: [block("b1", PAGE_ID), block("b2", PAGE_ID, has_children: true)], fetched_at: Time.current)
    assert_equal %w[b1 b2], NotionBlock.children_of(PAGE_ID).pluck(:notion_id)
    assert page.reload.root_children_fetched_at.present?

    # b2 gains a child level; then b1 moves under b2 and b3 appears at root
    M.replace_level(parent_id: "b2", page_id: PAGE_ID, blocks: [block("b1", "b2")], fetched_at: Time.current)
    M.replace_level(parent_id: PAGE_ID, page_id: PAGE_ID, blocks: [block("b2", PAGE_ID, has_children: true), block("b3", PAGE_ID)], fetched_at: Time.current)
    assert_equal %w[b2 b3], NotionBlock.children_of(PAGE_ID).pluck(:notion_id)
    assert_equal %w[b1], NotionBlock.children_of("b2").pluck(:notion_id)
    assert NotionBlock.find_by(notion_id: "b2").children_fetched_at.present?
    assert_equal 3, NotionBlock.where(page_id: PAGE_ID).count
  end

  test "owning_page_id resolves pages and cached blocks, nil otherwise" do
    M.upsert_page(page_obj)
    M.replace_level(parent_id: PAGE_ID, page_id: PAGE_ID, blocks: [block("b1", PAGE_ID)], fetched_at: Time.current)
    assert_equal PAGE_ID, M.owning_page_id(PAGE_ID.delete("-"))
    assert_equal PAGE_ID, M.owning_page_id("b1")
    assert_nil M.owning_page_id("nope")
  end

  test "upsert_data_source with fetched_at: nil never clears an existing fetched_at" do
    obj = { "object" => "data_source", "id" => DS_ID, "title" => [], "parent" => {}, "properties" => {}, "last_edited_time" => "2026-09-01T00:00:00.000Z", "in_trash" => false }
    M.upsert_data_source(obj, fetched_at: Time.current)
    row = M.upsert_data_source(obj, fetched_at: nil)
    assert row.fetched_at.present?
    fresh = M.upsert_data_source(obj.merge("id" => SecureRandom.uuid), fetched_at: nil)
    assert_nil fresh.fetched_at
  end

  test "a workspace-parented page stores a nil parent id" do
    obj = page_obj.merge("parent" => { "type" => "workspace", "workspace" => true })
    page = M.upsert_page(obj)
    assert_equal "workspace", page.notion_parent_type
    assert_nil page.notion_parent_id
    assert_nil page.database_id
  end
end
