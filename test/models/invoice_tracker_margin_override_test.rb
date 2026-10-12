require "test_helper"

class InvoiceTrackerMarginOverrideTest < ActiveSupport::TestCase
  test "the column is nullable with no default" do
    col = InvoiceTracker.columns_hash["target_margin_override"]
    assert col, "expected invoice_trackers.target_margin_override to exist"
    assert_nil col.default
    assert_not InvoiceTracker.column_names.include?("company_treasury_split")
  end

  test "margin_override reads the new column" do
    assert_nil InvoiceTracker.new.margin_override
    assert_equal BigDecimal("0.33"), InvoiceTracker.new(target_margin_override: 0.33).margin_override
  end

  # Between deploy and the manual migration the row still has the old column.
  test "margin_override falls back to the old column when the new one is absent" do
    it = InvoiceTracker.new
    it.stubs(:has_attribute?).with(:target_margin_override).returns(false)
    it.stubs(:[]).with(:company_treasury_split).returns(BigDecimal("0.3"))
    assert_equal BigDecimal("0.3"), it.margin_override
  end

  # Between deploy and the manual migration there are no override columns.
  test "recording an override is a no-op until its columns exist" do
    it = InvoiceTracker.new
    it.stubs(:has_attribute?).with(:payout_cap_override_by_id).returns(false)
    it.expects(:update!).never
    assert_nil it.record_payout_cap_override!(admin_user: AdminUser.new, reason: "x", check: nil)
    assert_not it.payout_cap_overridden?
    assert_nil it.clear_payout_cap_override!
  end
end
