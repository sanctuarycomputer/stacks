require "test_helper"

class ProfitShareTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @ps = ProfitShare.new
  end

  test "bill_line_item_key routes profit shares through the mapping engine" do
    assert_equal "profit_share", @ps.bill_line_item_key
    assert_includes QboBillAccountMapping::LINE_ITEM_KEYS, @ps.bill_line_item_key
  end
end
