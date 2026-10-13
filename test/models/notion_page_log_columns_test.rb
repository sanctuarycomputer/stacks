require 'test_helper'

class NotionPageLogColumnsTest < ActiveSupport::TestCase
  test "a page starts with no projects and no dates" do
    np = NotionPage.create!(notion_id: SecureRandom.uuid, data: {}).reload
    assert_equal [], np.project_ids
    assert_nil np.occurred_at
    assert_nil np.synced_at
  end

  test "a page is found by any one of its projects" do
    a, b, c = Array.new(3) { SecureRandom.uuid }
    hit = NotionPage.create!(notion_id: SecureRandom.uuid, data: {}, project_ids: [a, b])
    NotionPage.create!(notion_id: SecureRandom.uuid, data: {}, project_ids: [c])
    found = NotionPage.where("project_ids && ARRAY[?]::varchar[]", [b, SecureRandom.uuid])
    assert_equal [hit.id], found.pluck(:id)
  end

  test "the project list has a GIN index and the parent has a btree with the date" do
    indexes = ActiveRecord::Base.connection.indexes(:notion_pages).index_by(&:name)
    assert_equal :gin, indexes.fetch("index_notion_pages_on_project_ids").using
    assert_equal %w[notion_parent_id occurred_at], indexes.fetch("index_notion_pages_on_parent_and_occurred_at").columns
  end
end
