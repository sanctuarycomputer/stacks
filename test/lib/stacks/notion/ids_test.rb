require 'test_helper'

class StacksNotionIdsTest < ActiveSupport::TestCase
  DASHED = "4d9b46b8-bad5-4250-9f14-4347db37964d"

  test "normalize keeps a dashed uuid" do
    assert_equal DASHED, Stacks::Notion::Ids.normalize(DASHED)
  end

  test "normalize dashes a 32-hex id" do
    assert_equal DASHED, Stacks::Notion::Ids.normalize("4d9b46b8bad542509f144347db37964d")
  end

  test "normalize downcases and strips whitespace" do
    assert_equal DASHED, Stacks::Notion::Ids.normalize("  4D9B46B8BAD542509F144347DB37964D ")
  end

  test "normalize returns nil for garbage or nil" do
    assert_nil Stacks::Notion::Ids.normalize(nil)
    assert_nil Stacks::Notion::Ids.normalize("not-an-id")
    assert_nil Stacks::Notion::Ids.normalize("4d9b46b8bad542509f144347db3796")
  end

  test "valid? mirrors normalize" do
    assert Stacks::Notion::Ids.valid?(DASHED)
    refute Stacks::Notion::Ids.valid?("zzz")
  end
end
