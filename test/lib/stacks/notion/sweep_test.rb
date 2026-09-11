require 'test_helper'

class StacksNotionSweepTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  DS = "e5d5d0da-a85e-4b3f-b900-9fd06a315622"
  DB = "438196be-db11-412e-b8e7-37bc1bd75b2b"

  setup do
    Stacks::Utils.stubs(:config).returns({ notion: { token: "t" } })
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @client = Stacks::Notion.new
    travel_to Time.zone.parse("2026-09-10T12:00:00Z")
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page(id, last_edited)
    { "object" => "page", "id" => id, "last_edited_time" => last_edited, "in_trash" => false,
      "parent" => { "type" => "data_source_id", "data_source_id" => DS, "database_id" => DB },
      "properties" => { "Name" => { "type" => "title", "title" => [{ "plain_text" => id[0, 4] }] } }, "url" => "u" }
  end

  def ds(id, last_edited)
    { "object" => "data_source", "id" => id, "title" => [{ "plain_text" => "DS" }], "parent" => { "type" => "database_id", "database_id" => DB },
      "properties" => {}, "last_edited_time" => last_edited, "in_trash" => false }
  end

  def feed(results, next_cursor: nil)
    { "object" => "list", "results" => results, "next_cursor" => next_cursor, "has_more" => !next_cursor.nil?, "type" => "page_or_data_source", "page_or_data_source" => {} }
  end

  def sort_desc = { "timestamp" => "last_edited_time", "direction" => "descending" }

  test "walks the feed back to watermark minus overlap, dedupes across pages, upserts pages and data sources" do
    SourceSync.for(:notion_mirror).advance!(cursor: { "watermark" => "2026-09-10T11:30:00Z" })
    a, b, c, d = 4.times.map { SecureRandom.uuid }
    @client.expects(:search).with({ "page_size" => 100, "sort" => sort_desc }).returns(feed([page(a, "2026-09-10T11:58:00.000Z"), ds(b, "2026-09-10T11:40:00.000Z")], next_cursor: "c2"))
    @client.expects(:search).with({ "page_size" => 100, "sort" => sort_desc, "start_cursor" => "c2" }).returns(feed([page(a, "2026-09-10T11:58:00.000Z"), page(c, "2026-09-10T11:26:00.000Z"), page(d, "2026-09-10T11:20:00.000Z")]))

    stats = Stacks::Notion::Sweep.new(@client).run

    assert_equal 2, stats[:feed_requests]
    assert_equal 2, stats[:pages_upserted], "a (deduped) and c (inside the 5-minute overlap); d is older than watermark-overlap"
    assert_equal 1, stats[:data_sources_upserted]
    assert NotionPage.exists?(notion_id: c)
    refute NotionPage.exists?(notion_id: d)
    assert_equal "2026-09-10T11:58:00Z", SourceSync.for(:notion_mirror).reload.cursor["watermark"]
  end

  test "the watermark never passes run_started_at" do
    a = SecureRandom.uuid
    @client.stubs(:search).returns(feed([page(a, "2026-09-10T12:30:00.000Z")]))
    Stacks::Notion::Sweep.new(@client).run
    assert_equal "2026-09-10T12:00:00Z", SourceSync.for(:notion_mirror).reload.cursor["watermark"]
  end

  test "a walked page whose stamp moved is marked stale and its tree refreshed within the run" do
    a = SecureRandom.uuid
    Stacks::Notion::Mirror.upsert_page(page(a, "2026-09-10T11:00:00.000Z"))
    NotionPage.find_by!(notion_id: a).update!(tree_fetched_for_edited_at: Time.zone.parse("2026-09-10T11:00:00Z"), root_children_fetched_at: 1.hour.ago)
    @client.stubs(:search).returns(feed([page(a, "2026-09-10T11:50:00.000Z")]))
    @client.expects(:get_block_children).with(a, start_cursor: nil, page_size: 100).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })

    stats = Stacks::Notion::Sweep.new(@client).run

    assert_equal 1, stats[:trees_refreshed]
    row = NotionPage.find_by!(notion_id: a)
    assert_nil row.blocks_stale_at
    assert_equal Time.zone.parse("2026-09-10T11:50:00Z"), row.tree_fetched_for_edited_at
  end

  test "wanted_at pages are refreshed first and pages never walked are skipped" do
    never, wanted, stale = 3.times.map { SecureRandom.uuid }
    [never, wanted, stale].each { |id| Stacks::Notion::Mirror.upsert_page(page(id, "2026-09-10T11:00:00.000Z")) }
    NotionPage.find_by!(notion_id: wanted).update!(wanted_at: Time.current)
    NotionPage.find_by!(notion_id: stale).update!(blocks_stale_at: Time.current, tree_fetched_for_edited_at: 1.day.ago, root_children_fetched_at: 1.day.ago)
    @client.stubs(:search).returns(feed([]))
    seq = sequence("refresh order")
    empty = { "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false }
    @client.expects(:get_block_children).with(wanted, start_cursor: nil, page_size: 100).returns(empty).in_sequence(seq)
    @client.expects(:get_block_children).with(stale, start_cursor: nil, page_size: 100).returns(empty).in_sequence(seq)
    @client.expects(:get_block_children).with(never, start_cursor: nil, page_size: 100).never

    stats = Stacks::Notion::Sweep.new(@client).run
    assert_equal 2, stats[:trees_refreshed]
  end

  test "the run deadline stops tree refresh and leaves the pages flagged" do
    wanted, stale = 2.times.map { SecureRandom.uuid }
    [wanted, stale].each { |id| Stacks::Notion::Mirror.upsert_page(page(id, "2026-09-10T11:00:00.000Z")) }
    NotionPage.find_by!(notion_id: wanted).update!(wanted_at: Time.current)
    NotionPage.find_by!(notion_id: stale).update!(blocks_stale_at: Time.current, tree_fetched_for_edited_at: 1.day.ago, root_children_fetched_at: 1.day.ago)
    @client.stubs(:search).returns(feed([]))
    @client.expects(:get_block_children).never

    stats = Stacks::Notion::Sweep.new(@client, run_deadline: 0.seconds).run
    assert_equal 0, stats[:trees_refreshed]
    assert_equal 2, stats[:pages_still_stale]
  end

  test "recheck_after pages get one GET and are re-flagged only if the stamp moved" do
    a, b = 2.times.map { SecureRandom.uuid }
    [a, b].each do |id|
      Stacks::Notion::Mirror.upsert_page(page(id, "2026-09-10T11:00:00.000Z"))
      NotionPage.find_by!(notion_id: id).update!(recheck_after: 1.minute.ago, tree_fetched_for_edited_at: Time.zone.parse("2026-09-10T11:00:00Z"), root_children_fetched_at: 1.hour.ago)
    end
    @client.stubs(:search).returns(feed([]))
    @client.expects(:get_page).with(a).returns(page(a, "2026-09-10T11:00:00.000Z"))
    @client.expects(:get_page).with(b).returns(page(b, "2026-09-10T11:01:00.000Z"))
    @client.stubs(:get_block_children).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })

    stats = Stacks::Notion::Sweep.new(@client, run_deadline: 0.seconds).run

    assert_equal 2, stats[:rechecks]
    assert_nil NotionPage.find_by!(notion_id: a).recheck_after
    assert_nil NotionPage.find_by!(notion_id: a).blocks_stale_at
    assert NotionPage.find_by!(notion_id: b).blocks_stale_at.present?
  end

  test "a wanted_at page whose tree fetch loses access is marked access_lost and skipped next run" do
    a = SecureRandom.uuid
    Stacks::Notion::Mirror.upsert_page(page(a, "2026-09-10T11:00:00.000Z"))
    NotionPage.find_by!(notion_id: a).update!(wanted_at: Time.current)
    @client.stubs(:search).returns(feed([]))
    @client.expects(:get_block_children).with(a, start_cursor: nil, page_size: 100)
           .raises(Stacks::Notion::RequestError.new(404, { "object" => "error" }))

    stats = Stacks::Notion::Sweep.new(@client).run

    row = NotionPage.find_by!(notion_id: a)
    assert row.access_lost
    assert_nil row.wanted_at
    assert_nil row.blocks_stale_at
    assert_equal 1, stats[:pages_access_lost]

    @client.expects(:get_block_children).never
    Stacks::Notion::Sweep.new(@client).run
  end

  test "a nil watermark caps the first-run feed walk at FIRST_RUN_FEED_PAGES and still sets a watermark" do
    @client.stubs(:search).returns(feed([page(SecureRandom.uuid, "2026-09-10T11:59:00.000Z")], next_cursor: "next"))

    stats = Stacks::Notion::Sweep.new(@client).run

    assert_equal Stacks::Notion::Sweep::FIRST_RUN_FEED_PAGES, stats[:feed_requests]
    assert SourceSync.for(:notion_mirror).reload.cursor["watermark"].present?
  end

  test "refresh_trees! passes the remaining run budget as the tree fetcher deadline" do
    a = SecureRandom.uuid
    Stacks::Notion::Mirror.upsert_page(page(a, "2026-09-10T11:00:00.000Z"))
    NotionPage.find_by!(notion_id: a).update!(wanted_at: Time.current)
    @client.stubs(:search).returns(feed([]))
    Stacks::Notion::TreeFetcher.expects(:new)
      .with { |_c, **kw| kw[:deadline].is_a?(Float) && kw[:deadline] <= 0.5 }
      .returns(stub(walk: { complete: true, requests: 0 }))

    stats = Stacks::Notion::Sweep.new(@client, run_deadline: 0.5.seconds).run
    assert_equal 1, stats[:trees_refreshed]
  end

  test "the feed failing leaves the watermark alone" do
    SourceSync.for(:notion_mirror).advance!(cursor: { "watermark" => "2026-09-10T11:30:00Z" })
    @client.stubs(:search).raises(Stacks::Notion::RequestError.new(502, { "object" => "error" }))
    assert_raises(Stacks::Notion::RequestError) { Stacks::Notion::Sweep.new(@client).run }
    assert_equal "2026-09-10T11:30:00Z", SourceSync.for(:notion_mirror).reload.cursor["watermark"]
  end

  test "run_with_lock! returns nil when the advisory lock is held elsewhere" do
    other = ActiveRecord::Base.connection_pool.checkout
    other.execute("SELECT pg_advisory_lock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    assert_nil Stacks::Notion::Sweep.run_with_lock!(@client)
  ensure
    other.execute("SELECT pg_advisory_unlock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    ActiveRecord::Base.connection_pool.checkin(other)
  end
end
