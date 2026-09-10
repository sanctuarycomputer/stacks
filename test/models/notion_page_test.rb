require 'test_helper'

class NotionPageTest < ActiveSupport::TestCase
  LEADS_DB = Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS])

  def page!(database_id:, in_trash: false, deleted: false, **attrs)
    p = NotionPage.create!({ notion_id: SecureRandom.uuid, database_id: database_id, in_trash: in_trash,
                             data: { "properties" => {} } }.merge(attrs))
    p.destroy if deleted
    p
  end

  test "lead scope selects by database_id and excludes trashed and soft-deleted rows" do
    live = page!(database_id: LEADS_DB)
    page!(database_id: LEADS_DB, in_trash: true)
    page!(database_id: LEADS_DB, deleted: true)
    page!(database_id: SecureRandom.uuid)
    assert_equal [live.id], NotionPage.lead.pluck(:id)
  end

  test "human_operating_manual scope selects by database_id" do
    hom = page!(database_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:HUMAN_OPERATING_MANUALS]))
    assert_equal [hom.id], NotionPage.human_operating_manual.pluck(:id)
  end

  test "created_at is nil-safe when data has no created_time" do
    p = page!(database_id: LEADS_DB)
    assert_nil p.created_at
    p.update!(data: { "created_time" => "2024-01-02T03:04:00.000Z" })
    assert_equal DateTime.parse("2024-01-02T03:04:00.000Z"), p.created_at
  end

  test "Stacks::Notion::Lead.all uses the lead scope" do
    page!(database_id: LEADS_DB)
    assert_equal 1, Stacks::Notion::Lead.all.size
    assert_kind_of Stacks::Notion::Lead, Stacks::Notion::Lead.all.first
  end

  test "status_history is gone" do
    refute NotionPage.new.respond_to?(:status_history)
  end

  test "new tables exist with unique notion_id" do
    NotionBlock.create!(notion_id: "b1", parent_id: "p1", page_id: "p1", position: 0, has_children: false, data: {})
    assert_raises(ActiveRecord::RecordNotUnique) { NotionBlock.create!(notion_id: "b1", parent_id: "p1", page_id: "p1", position: 1, has_children: false, data: {}) }
    NotionDataSource.create!(notion_id: "ds1", database_id: "db1", title: "T", data: {})
    NotionDatabase.create!(notion_id: "db1", title: "T", data: {})
  end
end
