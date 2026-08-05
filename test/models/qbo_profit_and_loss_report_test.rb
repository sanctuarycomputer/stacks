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

  test "data_for_enterprise assigns profit_margin in the :All branch (D1)" do
    rows = [
      ["Total Income", "1000.0"],
      ["Total Cost of Goods Sold", "200.0"],
      ["Total Expenses", "100.0"],
      ["Net Income", "700.0"],
    ]
    report = QboProfitAndLossReport.create!(
      qbo_account: @qa,
      starts_at: Date.new(2099, 3, 1),
      ends_at: Date.new(2099, 3, 31),
      data: { cash: { rows: rows }, accrual: { rows: rows } },
    )

    result = report.data_for_enterprise(@sanctuary, "cash", "Mar 2099", :All)
    assert_equal 1000.0, result[:revenue]
    assert_equal 700.0,  result[:net_revenue]
    assert_equal 70.0,   result[:profit_margin],
      "profit_margin must be net_revenue/revenue*100, not left at 0"
  end

  test "data_for_enterprise assigns profit_margin in the vertical branch (D1)" do
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
      starts_at: Date.new(2099, 4, 1),
      ends_at: Date.new(2099, 4, 30),
      data: { cash: { rows: rows }, accrual: { rows: rows } },
    )

    result = report.data_for_enterprise(@sanctuary, "cash", "Apr 2099", :SC)
    assert_equal 700.0, result[:net_revenue]
    assert_equal 70.0,  result[:profit_margin],
      "profit_margin must be net_revenue/revenue*100, not left at 0"
  end

  test "data_for_enterprise :All does not substring-match row labels (D2)" do
    # find_rows was called with a String, so labels_array.include?(r[0]) was
    # String#include? — a SUBSTRING test. A row labeled exactly "Income" (the
    # QBO section header) matched "Total Income" and was summed into revenue.
    rows = [
      ["Income", "999.0"],  # section header row — must NOT count as revenue
      ["Total Income", "1000.0"],
      ["Total Cost of Goods Sold", "200.0"],
      ["Expenses", "888.0"],  # section header row — must NOT count as expenses
      ["Total Expenses", "100.0"],
      ["Net Income", "700.0"],
    ]
    report = QboProfitAndLossReport.create!(
      qbo_account: @qa,
      starts_at: Date.new(2099, 5, 1),
      ends_at: Date.new(2099, 5, 31),
      data: { cash: { rows: rows }, accrual: { rows: rows } },
    )

    result = report.data_for_enterprise(@sanctuary, "cash", "May 2099", :All)
    assert_equal 1000.0, result[:revenue], "row labeled 'Income' must not be summed into revenue"
    assert_equal 100.0,  result[:expenses], "row labeled 'Expenses' must not be summed into expenses"
    assert_equal 700.0,  result[:net_revenue]
  end
end
