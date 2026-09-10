require 'test_helper'

class StacksNotionTreeFetcherTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  PAGE = "3bf131fe-a2c7-8092-87f3-c668e91d5332"

  setup do
    Stacks::Utils.stubs(:config).returns({ notion: { token: "t" } })
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @client = Stacks::Notion.new
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page_obj(last_edited: "2026-09-10T10:00:00.000Z")
    { "object" => "page", "id" => PAGE, "last_edited_time" => last_edited, "in_trash" => false,
      "parent" => { "type" => "workspace", "workspace" => true },
      "properties" => { "title" => { "type" => "title", "title" => [{ "plain_text" => "Guide" }] } }, "url" => "u" }
  end

  def block(id, parent, has_children: false)
    { "object" => "block", "id" => id, "type" => "paragraph", "has_children" => has_children,
      "parent" => { "type" => "page_id", "page_id" => parent }, "paragraph" => { "rich_text" => [] } }
  end

  def list(results, next_cursor: nil)
    { "object" => "list", "results" => results, "next_cursor" => next_cursor, "has_more" => !next_cursor.nil?, "type" => "block", "block" => {} }
  end

  test "walks every level, paginating, and stamps tree_fetched_for_edited_at" do
    travel_to Time.zone.parse("2026-09-10T12:00:00Z")
    Stacks::Notion::Mirror.upsert_page(page_obj)
    @client.expects(:get_block_children).with(PAGE, start_cursor: nil, page_size: 100).returns(list([block("b1", PAGE, has_children: true)], next_cursor: "c2"))
    @client.expects(:get_block_children).with(PAGE, start_cursor: "c2", page_size: 100).returns(list([block("b2", PAGE)]))
    @client.expects(:get_block_children).with("b1", start_cursor: nil, page_size: 100).returns(list([block("b3", "b1")]))

    result = Stacks::Notion::TreeFetcher.new(@client).walk(PAGE)

    assert_equal({ complete: true, requests: 3 }, result)
    page = NotionPage.find_by!(notion_id: PAGE)
    assert_equal Time.zone.parse("2026-09-10T10:00:00Z"), page.tree_fetched_for_edited_at
    assert_nil page.blocks_stale_at
    assert_nil page.recheck_after
    assert_equal %w[b1 b2], NotionBlock.children_of(PAGE).pluck(:notion_id)
    assert_equal %w[b3], NotionBlock.children_of("b1").pluck(:notion_id)
  end

  test "fetches the page object first when the row is missing" do
    @client.expects(:get_page).with(PAGE).returns(page_obj)
    @client.stubs(:get_block_children).returns(list([]))
    Stacks::Notion::TreeFetcher.new(@client).walk(PAGE)
    assert NotionPage.exists?(notion_id: PAGE)
  end

  test "a fresh tree makes no requests" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    Stacks::Notion::Mirror.replace_level(parent_id: PAGE, page_id: PAGE, blocks: [block("b1", PAGE)], fetched_at: Time.current)
    NotionPage.find_by!(notion_id: PAGE).update!(tree_fetched_for_edited_at: Time.zone.parse("2026-09-10T10:00:00Z"))
    @client.expects(:get_block_children).never
    assert_equal({ complete: true, requests: 0 }, Stacks::Notion::TreeFetcher.new(@client).walk(PAGE))
  end

  test "a stale page refetches only levels older than blocks_stale_at" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    Stacks::Notion::Mirror.replace_level(parent_id: PAGE, page_id: PAGE, blocks: [block("b1", PAGE, has_children: true)], fetched_at: 1.hour.ago)
    Stacks::Notion::Mirror.replace_level(parent_id: "b1", page_id: PAGE, blocks: [block("b3", "b1")], fetched_at: 1.minute.from_now)
    NotionPage.find_by!(notion_id: PAGE).update!(blocks_stale_at: Time.current, tree_fetched_for_edited_at: 1.day.ago)
    @client.expects(:get_block_children).with(PAGE, start_cursor: nil, page_size: 100).returns(list([block("b1", PAGE, has_children: true)]))
    @client.expects(:get_block_children).with("b1", start_cursor: nil, page_size: 100).never
    assert_equal({ complete: true, requests: 1 }, Stacks::Notion::TreeFetcher.new(@client).walk(PAGE))
    assert_nil NotionPage.find_by!(notion_id: PAGE).blocks_stale_at
  end

  test "the deadline stops the walk, sets wanted_at, and the next walk resumes" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    @client.stubs(:get_block_children).with(PAGE, start_cursor: nil, page_size: 100).returns(list([block("b1", PAGE, has_children: true), block("b2", PAGE, has_children: true)]))
    @client.stubs(:get_block_children).with("b1", start_cursor: nil, page_size: 100).returns(list([]))
    @client.stubs(:get_block_children).with("b2", start_cursor: nil, page_size: 100).returns(list([]))

    fetcher = Stacks::Notion::TreeFetcher.new(@client, deadline: 0.0) # expires after the first level
    assert_equal({ complete: false, requests: 1 }, fetcher.walk(PAGE))
    assert NotionPage.find_by!(notion_id: PAGE).wanted_at.present?

    assert_equal({ complete: true, requests: 2 }, Stacks::Notion::TreeFetcher.new(@client).walk(PAGE))
    assert_nil NotionPage.find_by!(notion_id: PAGE).wanted_at
  end

  test "an edit during the walk leaves the page stale" do
    Stacks::Notion::Mirror.upsert_page(page_obj)
    # The sweep is what normally moves the stamp mid-walk; simulate it from inside the stub.
    @client.stubs(:get_block_children)
           .with { |*| Stacks::Notion::Mirror.upsert_page(page_obj(last_edited: "2026-09-10T10:05:00.000Z")); true }
           .returns(list([block("b1", PAGE)]))
    result = Stacks::Notion::TreeFetcher.new(@client).walk(PAGE)
    refute result[:complete]
    assert NotionPage.find_by!(notion_id: PAGE).blocks_stale_at.present?
  end

  test "a walk within 60s of the edit stamp sets recheck_after" do
    travel_to Time.zone.parse("2026-09-10T10:00:30Z")
    Stacks::Notion::Mirror.upsert_page(page_obj(last_edited: "2026-09-10T10:00:00.000Z"))
    @client.stubs(:get_block_children).returns(list([]))
    Stacks::Notion::TreeFetcher.new(@client).walk(PAGE)
    assert_equal Time.zone.parse("2026-09-10T10:01:00Z"), NotionPage.find_by!(notion_id: PAGE).recheck_after
  end
end
