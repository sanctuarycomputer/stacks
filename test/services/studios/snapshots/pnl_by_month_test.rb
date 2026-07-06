require "test_helper"

class Studios::Snapshots::PnlByMonthTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @account = qbo_accounts(:one)
    @g3d = Studio.create!(name: "garden3d", mini_name: "g3d")
    @xxix = Studio.create!(name: "XXIX", mini_name: "xxix", accounting_prefix: "XXIX")
  end

  def seed_month!(month, method, rows)
    report = QboProfitAndLossReport.find_or_create_by!(
      qbo_account: @account, starts_at: month, ends_at: month.end_of_month
    ) { |r| r.data = {} }
    rows.each_with_index do |(label, amount), position|
      QboProfitAndLossLineItem.create!(
        qbo_account: @account, qbo_profit_and_loss_report: report,
        starts_at: month, accounting_method: method,
        position: position, label: label, amount: amount
      )
    end
  end

  test "garden3d reads the four total rows per month" do
    seed_month!(Date.new(2024, 1, 1), "cash", [
      ["Total Income", 100], ["Total Cost of Goods Sold", 30],
      ["Total Expenses", 20], ["Net Operating Income", 50]
    ])
    seed_month!(Date.new(2024, 2, 1), "cash", [["Total Income", 10]])

    out = Studios::Snapshots::PnlByMonth.call(
      studio: @g3d, from: Date.new(2024, 1, 1), through: Date.new(2024, 2, 29),
      qbo_account: @account
    )

    jan = out["cash"][Date.new(2024, 1, 1)]
    assert_equal 100.0, jan[:income]
    assert_equal 30.0, jan[:cost_of_goods_sold]
    assert_equal 20.0, jan[:expenses]
    assert_equal 50.0, jan[:net_operating_income]

    feb = out["cash"][Date.new(2024, 2, 1)]
    assert_equal 10.0, feb[:income]
    assert_equal 0.0, feb[:cost_of_goods_sold] # find_row default when label absent
  end

  test "prefixed studio takes FIRST matching row by position, then derives" do
    seed_month!(Date.new(2024, 1, 1), "cash", [
      ["Revenue - XXIX", 200],          # first match wins for income
      ["Total Revenue - XXIX", 999],    # ignored — later position
      ["Total COS - XXIX", 80],
      ["Tools and Subscriptions - XXIX", 15]
    ])

    out = Studios::Snapshots::PnlByMonth.call(
      studio: @xxix, from: Date.new(2024, 1, 1), through: Date.new(2024, 1, 31),
      qbo_account: @account
    )

    jan = out["cash"][Date.new(2024, 1, 1)]
    assert_equal 200.0, jan[:income]
    assert_equal 65.0, jan[:cost_of_goods_sold]       # 80 - 15
    assert_equal 15.0, jan[:expenses]
    assert_equal 120.0, jan[:net_operating_income]    # 200 - 80
  end

  test "months without line items are absent" do
    out = Studios::Snapshots::PnlByMonth.call(
      studio: @g3d, from: Date.new(2024, 1, 1), through: Date.new(2024, 3, 31),
      qbo_account: @account
    )
    assert_equal({}, out["cash"])
    assert_equal({}, out["accrual"])
  end

  test "methods are kept separate" do
    seed_month!(Date.new(2024, 1, 1), "cash", [["Total Income", 100]])
    seed_month!(Date.new(2024, 1, 1), "accrual", [["Total Income", 140]])

    out = Studios::Snapshots::PnlByMonth.call(
      studio: @g3d, from: Date.new(2024, 1, 1), through: Date.new(2024, 1, 31),
      qbo_account: @account
    )
    assert_equal 100.0, out["cash"][Date.new(2024, 1, 1)][:income]
    assert_equal 140.0, out["accrual"][Date.new(2024, 1, 1)][:income]
  end
end
