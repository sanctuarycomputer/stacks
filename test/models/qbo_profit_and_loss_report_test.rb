require "test_helper"

class QboProfitAndLossReportTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary, client_id: "c", client_secret: "s", realm_id: "r#{SecureRandom.hex(3)}",
    )
  end

  test "data_for_enterprise handles vertical-tagged rows that appear after Total Expenses (Other Income/Expense sections)" do
    # Real QBO data shape: Income / COGS / Expenses sections with Totals,
    # then "Other Income" / "Other Expense" rows BELOW Total Expenses. A
    # vertical-tagged row in the below-the-line section has no following
    # Total X line — that's the case that used to NoMethodError on
    # `top_level_category_row[0]`.
    rows = [
      ["[SC] Service revenue", "1000.0"],
      ["Total Income", "1000.0"],
      ["[SC] Subcontractors", "200.0"],
      ["Total Cost of Goods Sold", "200.0"],
      ["[SC] Software", "100.0"],
      ["Total Expenses", "100.0"],
      ["Net Income", "700.0"],
      ["[SC] Depreciation", "50.0"],  # below-the-line, NO following Total X
    ]
    report = QboProfitAndLossReport.create!(
      qbo_account: @qa,
      starts_at: Date.new(2099, 1, 1),
      ends_at: Date.new(2099, 1, 31),
      data: { cash: { rows: rows }, accrual: { rows: rows } },
    )

    result = nil
    assert_nothing_raised do
      result = report.data_for_enterprise(@sanctuary, "cash", "Jan 2099", :SC)
    end
    assert_equal 1000.0, result[:revenue]
    assert_equal 200.0,  result[:cogs]
    assert_equal 100.0,  result[:expenses]
    # net_revenue = revenue - cogs - expenses; the orphaned Depreciation row
    # is intentionally NOT subtracted (it doesn't belong to any main section).
    assert_equal 700.0,  result[:net_revenue]
  end

  test "data_for_enterprise still buckets correctly when every vertical row has a parent section" do
    rows = [
      ["[SC] Service revenue", "1000.0"],
      ["Total Income", "1000.0"],
      ["[SC] Subcontractors", "200.0"],
      ["Total Cost of Goods Sold", "200.0"],
      ["[SC] Software", "100.0"],
      ["Total Expenses", "100.0"],
      ["Net Income", "700.0"],
    ]
    report = QboProfitAndLossReport.create!(
      qbo_account: @qa,
      starts_at: Date.new(2099, 2, 1),
      ends_at: Date.new(2099, 2, 28),
      data: { cash: { rows: rows }, accrual: { rows: rows } },
    )

    result = report.data_for_enterprise(@sanctuary, "cash", "Feb 2099", :SC)
    assert_equal 1000.0, result[:revenue]
    assert_equal 200.0,  result[:cogs]
    assert_equal 100.0,  result[:expenses]
    assert_equal 700.0,  result[:net_revenue]
  end

  test "find_or_fetch_for_range creates line items for monthly ranges" do
    cash = mock; cash.stubs(:all_rows).returns([["Total Income", 10]])
    accrual = mock; accrual.stubs(:all_rows).returns([["Total Income", 12]])
    @qa.stubs(:fetch_profit_and_loss_report_for_range)
      .returns(cash).then.returns(accrual)

    report = QboProfitAndLossReport.find_or_fetch_for_range(
      Date.new(2024, 5, 1), Date.new(2024, 5, 31), false, @qa
    )
    assert_equal 2, QboProfitAndLossLineItem.where(qbo_profit_and_loss_report: report).count
  end
end
