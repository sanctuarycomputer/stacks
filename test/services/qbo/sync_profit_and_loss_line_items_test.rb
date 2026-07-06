require "test_helper"

class Qbo::SyncProfitAndLossLineItemsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @account = qbo_accounts(:one)
  end

  def build_report(starts_at:, ends_at:, data:)
    QboProfitAndLossReport.create!(
      qbo_account: @account,
      starts_at: starts_at,
      ends_at: ends_at,
      data: data
    )
  end

  test "explodes a monthly report into line items for both methods" do
    report = build_report(
      starts_at: Date.new(2024, 3, 1),
      ends_at: Date.new(2024, 3, 31),
      data: {
        cash: { rows: [["Total Income", "100.5"], ["Total Expenses", "40"]] },
        accrual: { rows: [["Total Income", "120"]] }
      }
    )

    assert_equal :synced, Qbo::SyncProfitAndLossLineItems.call(report)

    items = QboProfitAndLossLineItem.where(qbo_profit_and_loss_report_id: report.id)
    assert_equal 3, items.count

    cash_income = items.find_by(accounting_method: "cash", label: "Total Income")
    assert_equal Date.new(2024, 3, 1), cash_income.starts_at
    assert_equal 0, cash_income.position
    assert_equal 100.5, cash_income.amount.to_f
    assert_equal @account.id, cash_income.qbo_account_id

    cash_expenses = items.find_by(accounting_method: "cash", label: "Total Expenses")
    assert_equal 1, cash_expenses.position
  end

  test "handles freshly-created reports whose data hash still has symbol keys" do
    # create! leaves symbol keys in the in-memory attribute until reload
    report = build_report(
      starts_at: Date.new(2024, 4, 1),
      ends_at: Date.new(2024, 4, 30),
      data: { cash: { rows: [["Total Income", 55]] }, accrual: { rows: [] } }
    )
    # Do NOT reload — the service must cope with either key type.
    assert_equal :synced, Qbo::SyncProfitAndLossLineItems.call(report)
    assert_equal 1, QboProfitAndLossLineItem.where(qbo_profit_and_loss_report: report).count
  end

  test "is idempotent — re-running replaces rows instead of duplicating" do
    report = build_report(
      starts_at: Date.new(2024, 3, 1),
      ends_at: Date.new(2024, 3, 31),
      data: { cash: { rows: [["Total Income", 1]] }, accrual: { rows: [] } }
    )
    Qbo::SyncProfitAndLossLineItems.call(report)
    Qbo::SyncProfitAndLossLineItems.call(report)
    assert_equal 1, QboProfitAndLossLineItem.where(qbo_profit_and_loss_report: report).count
  end

  test "skips non-monthly reports" do
    report = build_report(
      starts_at: Date.new(2024, 1, 1),
      ends_at: Date.new(2024, 3, 31),
      data: { cash: { rows: [["Total Income", 1]] }, accrual: { rows: [] } }
    )
    assert_equal :not_monthly, Qbo::SyncProfitAndLossLineItems.call(report)
    assert_equal 0, QboProfitAndLossLineItem.count
  end

  test "nil row values coerce to 0 (find_row .to_f parity)" do
    report = build_report(
      starts_at: Date.new(2024, 3, 1),
      ends_at: Date.new(2024, 3, 31),
      data: { cash: { rows: [["Income Section Header", nil]] }, accrual: { rows: [] } }
    )
    Qbo::SyncProfitAndLossLineItems.call(report)
    assert_equal 0.0, QboProfitAndLossLineItem.last.amount.to_f
  end

  test "line items cascade-delete when the report row is delete_all'd" do
    report = build_report(
      starts_at: Date.new(2024, 3, 1),
      ends_at: Date.new(2024, 3, 31),
      data: { cash: { rows: [["Total Income", 1]] }, accrual: { rows: [] } }
    )
    Qbo::SyncProfitAndLossLineItems.call(report)
    QboProfitAndLossReport.where(id: report.id).delete_all
    assert_equal 0, QboProfitAndLossLineItem.count
  end
end
