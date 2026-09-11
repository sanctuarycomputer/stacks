require 'test_helper'

class StacksNotionReconcileTest < ActiveSupport::TestCase
  setup do
    Stacks::Utils.stubs(:config).returns({ notion: { token: "t" } })
    ENV["NOTION_RPS"] = "1000"
    Stacks::Notion.reset_pacer!
    @client = Stacks::Notion.new
  end
  teardown { ENV["NOTION_RPS"] = "1000" } # restore the test_helper default, never delete

  def page(id, last_edited: "2026-09-01T00:00:00.000Z", in_trash: false) = { "object" => "page", "id" => id, "last_edited_time" => last_edited, "in_trash" => in_trash, "parent" => { "type" => "workspace", "workspace" => true }, "properties" => {}, "url" => "u" }

  test "unseen pages are disambiguated: trashed → in_trash, 404 → access_lost; drift is counted" do
    seen, trashed, gone, drifted = 4.times.map { SecureRandom.uuid }
    [seen, trashed, gone].each { |id| Stacks::Notion::Mirror.upsert_page(page(id)) }
    Stacks::Notion::Mirror.upsert_page(page(drifted, last_edited: "2026-08-01T00:00:00.000Z"))
    @client.stubs(:search).returns({ "object" => "list", "results" => [page(seen), page(drifted, last_edited: "2026-09-05T00:00:00.000Z")], "next_cursor" => nil, "has_more" => false })
    @client.expects(:get_page).with(trashed).returns(page(trashed, in_trash: true))
    @client.expects(:get_page).with(gone).raises(Stacks::Notion::RequestError.new(404, { "object" => "error", "code" => "object_not_found" }))

    stats = Stacks::Notion::Reconcile.new(@client).run

    assert_equal({ seen: 2, checked: 2, trashed: 1, access_lost: 1, drift: 1 }, stats)
    assert NotionPage.find_by!(notion_id: trashed).in_trash
    assert NotionPage.find_by!(notion_id: gone).access_lost
    assert_equal Time.zone.parse("2026-09-05T00:00:00Z"), NotionPage.find_by!(notion_id: drifted).notion_last_edited_at
  end

  test "the disambiguation limit bounds requests across pages and data sources" do
    ids = 3.times.map { SecureRandom.uuid }
    ids.each { |id| Stacks::Notion::Mirror.upsert_page(page(id)) }
    NotionDataSource.create!(notion_id: SecureRandom.uuid, title: "DS", data: {})
    @client.stubs(:search).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })
    @client.expects(:get_page).twice.with { |id| ids.include?(id) }.returns(*ids.first(2).map { |id| page(id, in_trash: true) })
    @client.expects(:get_data_source).never
    stats = Stacks::Notion::Reconcile.new(@client, disambiguation_limit: 2).run
    assert_equal 2, stats[:checked]
    assert_equal 2, stats[:trashed]
  end

  test "unseen data sources are disambiguated too" do
    ds = NotionDataSource.create!(notion_id: SecureRandom.uuid, title: "DS", data: {})
    @client.stubs(:search).returns({ "object" => "list", "results" => [], "next_cursor" => nil, "has_more" => false })
    @client.expects(:get_data_source).with(ds.notion_id).raises(Stacks::Notion::RequestError.new(404, { "object" => "error" }))
    stats = Stacks::Notion::Reconcile.new(@client).run
    assert_equal 1, stats[:access_lost]
    assert ds.reload.in_trash
  end
end
