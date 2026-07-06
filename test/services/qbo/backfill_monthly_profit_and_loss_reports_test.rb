require "test_helper"

class Qbo::BackfillMonthlyProfitAndLossReportsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @account = qbo_accounts(:one)
  end

  test "syncs line items for existing months and fetches missing ones" do
    existing = QboProfitAndLossReport.create!(
      qbo_account: @account,
      starts_at: Date.new(2024, 1, 1),
      ends_at: Date.new(2024, 1, 31),
      data: { cash: { rows: [["Total Income", 5]] }, accrual: { rows: [] } }
    )

    # Feb exists in the DB (so line-item inserts have a valid FK target) but
    # the service must see it as MISSING so it takes the fetch path. Stub the
    # existence probe per-month, and stub the fetch (no network in tests).
    fetched = QboProfitAndLossReport.create!(
      qbo_account: @account,
      starts_at: Date.new(2024, 2, 1),
      ends_at: Date.new(2024, 2, 29),
      data: { cash: { rows: [["Total Income", 7]] }, accrual: { rows: [] } }
    )
    QboProfitAndLossReport.stubs(:find_by)
      .with(qbo_account: @account, starts_at: Date.new(2024, 1, 1), ends_at: Date.new(2024, 1, 31))
      .returns(existing)
    QboProfitAndLossReport.stubs(:find_by)
      .with(qbo_account: @account, starts_at: Date.new(2024, 2, 1), ends_at: Date.new(2024, 2, 29))
      .returns(nil)
    QboProfitAndLossReport.stubs(:find_or_fetch_for_range)
      .with(Date.new(2024, 2, 1), Date.new(2024, 2, 29), false, @account)
      .returns(fetched)

    summary = Qbo::BackfillMonthlyProfitAndLossReports.call(
      qbo_account: @account,
      from: Date.new(2024, 1, 1),
      through: Date.new(2024, 2, 29),
      sleep_between_fetches: 0
    )

    assert_equal 1, summary[:existing]
    assert_equal 1, summary[:fetched]
    assert_equal [], summary[:failed]
    assert_equal 2, summary[:line_item_reports]
    assert QboProfitAndLossLineItem.where(qbo_profit_and_loss_report_id: existing.id).exists?
  end

  test "a failed fetch is recorded and does not abort the run" do
    QboProfitAndLossReport.stubs(:find_or_fetch_for_range).raises(StandardError.new("QBO down"))

    summary = Qbo::BackfillMonthlyProfitAndLossReports.call(
      qbo_account: @account,
      from: Date.new(2024, 1, 1),
      through: Date.new(2024, 2, 29),
      sleep_between_fetches: 0
    )

    assert_equal [Date.new(2024, 1, 1), Date.new(2024, 2, 1)], summary[:failed]
    assert_equal 0, summary[:line_item_reports]
  end

  test "a failed line-item sync is recorded and does not abort the run" do
    QboProfitAndLossReport.create!(
      qbo_account: @account,
      starts_at: Date.new(2024, 1, 1),
      ends_at: Date.new(2024, 1, 31),
      data: { cash: { rows: [["Total Income", 5]] }, accrual: { rows: [] } }
    )
    feb = QboProfitAndLossReport.create!(
      qbo_account: @account,
      starts_at: Date.new(2024, 2, 1),
      ends_at: Date.new(2024, 2, 29),
      data: { cash: { rows: [["Total Income", 7]] }, accrual: { rows: [] } }
    )

    # Jan's sync raises (e.g. a DB error from insert_all!); Feb's succeeds,
    # proving the run continued past the failure.
    Qbo::SyncProfitAndLossLineItems.stubs(:call).raises(StandardError.new("insert_all! blew up"))
    Qbo::SyncProfitAndLossLineItems.stubs(:call).with(feb).returns(:synced)

    summary = nil
    assert_nothing_raised do
      summary = Qbo::BackfillMonthlyProfitAndLossReports.call(
        qbo_account: @account,
        from: Date.new(2024, 1, 1),
        through: Date.new(2024, 2, 29),
        sleep_between_fetches: 0
      )
    end

    assert_equal [Date.new(2024, 1, 1)], summary[:failed]
    assert_equal 2, summary[:existing]
    assert_equal 1, summary[:line_item_reports]
  end
end
