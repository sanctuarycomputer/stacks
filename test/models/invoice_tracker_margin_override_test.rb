require "test_helper"

class InvoiceTrackerMarginOverrideTest < ActiveSupport::TestCase
  test "the column is nullable with no default" do
    col = InvoiceTracker.columns_hash["target_margin_override"]
    assert col, "expected invoice_trackers.target_margin_override to exist"
    assert_nil col.default
    assert_not InvoiceTracker.column_names.include?("company_treasury_split")
  end

  test "a tracker with no recorded override has nothing to clear" do
    it = InvoiceTracker.new
    it.expects(:update!).never
    assert_not it.payout_cap_overridden?
    assert_nil it.clear_payout_cap_override!
  end
end
