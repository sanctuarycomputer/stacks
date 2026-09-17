require "test_helper"

class ContributorProjections::ResultTest < ActiveSupport::TestCase
  SEP = Date.new(2026, 9, 1)
  OCT = Date.new(2026, 10, 1)

  def line(kind:, ledger_id:, enterprise_id:, contributor_id:, amount:, month:, hours: nil, tentative: false)
    ContributorProjections::Line.new(kind: kind, ledger_id: ledger_id, enterprise_id: enterprise_id, contributor_id: contributor_id,
                                     project_tracker_id: 1, project_tracker_name: "T", hours: hours, rate: 200.0, amount: amount,
                                     description: "d", tentative: tentative, rate_mismatch: false, month: month)
  end

  def result(lines)
    ContributorProjections::Result.new(
      horizon: ContributorProjections::Horizon.current(Date.new(2026, 9, 8)),
      lines: lines, skipped: { unmapped_person: 2 }, skipped_details: { unmapped_person: %w[a b] }, as_of: DateTime.new(2026, 9, 8, 3),
    )
  end

  def lines
    [
      line(kind: :individual_contributor, ledger_id: 10, enterprise_id: 1, contributor_id: 100, amount: 1000.0, hours: 5.0, month: SEP),
      line(kind: :account_lead, ledger_id: 11, enterprise_id: 1, contributor_id: 101, amount: 80.0, hours: 5.0, month: SEP),
      line(kind: :individual_contributor, ledger_id: 10, enterprise_id: 1, contributor_id: 100, amount: 500.0, hours: 2.5, month: OCT, tentative: true),
      line(kind: :pay_stub, ledger_id: 20, enterprise_id: 2, contributor_id: 100, amount: 300.0, hours: 3.0, month: SEP),
      line(kind: :recurring_adjustment, ledger_id: 10, enterprise_id: 1, contributor_id: 100, amount: -50.0, month: SEP),
    ]
  end

  test "by_contributor_month sums across ledgers and fills every horizon month" do
    r = result(lines)
    c = Contributor.new; c.stubs(:id).returns(100)
    by = r.by_contributor_month(c)
    assert_equal r.horizon.month_keys, by.keys
    assert_in_delta 1250.0, by[SEP][:amount], 0.001          # 1000 + 300 - 50
    assert_in_delta 1250.0, by[SEP][:confirmed_amount], 0.001
    assert_in_delta 8.0, by[SEP][:hours], 0.001              # IC 5 + pay stub 3; adjustment has no hours
    assert_in_delta 500.0, by[OCT][:amount], 0.001
    assert_in_delta 500.0, by[OCT][:tentative_amount], 0.001
    assert_in_delta 0.0, by[OCT][:confirmed_amount], 0.001
    assert_equal 0.0, by[Date.new(2026, 11, 1)][:amount]
    assert_equal [], by[Date.new(2026, 11, 1)][:lines]
  end

  test "by_contributor_month scoped to one ledger" do
    r = result(lines)
    c = Contributor.new; c.stubs(:id).returns(100)
    l = Ledger.new; l.stubs(:id).returns(20)
    assert_in_delta 300.0, r.by_contributor_month(c, ledger: l)[SEP][:amount], 0.001
  end

  test "lines within a month are ordered confirmed first, then tracker, then KIND_ORDER" do
    r = result(lines)
    c = Contributor.new; c.stubs(:id).returns(100)
    kinds = r.by_contributor_month(c)[SEP][:lines].map(&:kind)
    assert_equal %i[individual_contributor pay_stub recurring_adjustment], kinds
  end

  test "by_enterprise_month and totals_by_month" do
    r = result(lines)
    by = r.by_enterprise_month
    assert_in_delta 1030.0, by[1][SEP][:amount], 0.001        # 1000 + 80 - 50
    assert_in_delta 300.0, by[2][SEP][:amount], 0.001
    assert_in_delta 1330.0, r.totals_by_month[SEP][:amount], 0.001
    assert_in_delta 1030.0, r.totals_by_month(enterprise_id: 1)[SEP][:amount], 0.001
    assert_in_delta 500.0, r.totals_by_month[OCT][:tentative_amount], 0.001
  end

  test "by_contributor_totals scoped by enterprise" do
    r = result(lines)
    all = r.by_contributor_totals
    assert_in_delta 1250.0, all[100][SEP][:amount], 0.001
    assert_in_delta 80.0, all[101][SEP][:amount], 0.001
    scoped = r.by_contributor_totals(enterprise_id: 2)
    assert_equal [100], scoped.keys
    assert_in_delta 300.0, scoped[100][SEP][:amount], 0.001
  end

  test "by_ledger_month groups raw lines" do
    r = result(lines)
    assert_equal 2, r.by_ledger_month[10][SEP].size
    assert_equal 1, r.by_ledger_month[20][SEP].size
  end

  test "stale? and skipped_total" do
    r = result(lines)
    assert_not r.stale?(Date.new(2026, 9, 9))
    assert r.stale?(Date.new(2026, 9, 12))
    assert_equal 2, r.skipped_total
  end

  test "contributors resolves the referenced ids" do
    fp = ForecastPerson.create!(forecast_id: 990_001, email: "res@example.com", data: {})
    real = fp.contributor
    r = result([line(kind: :pay_stub, ledger_id: 1, enterprise_id: 1, contributor_id: real.id, amount: 1.0, hours: 1.0, month: SEP)])
    assert_equal real, r.contributors[real.id]
  end

  test "by_contributor_month carries allocated, capacity, and utilization per month" do
    c = Contributor.new; c.stubs(:id).returns(100)
    r = ContributorProjections::Result.new(
      horizon: ContributorProjections::Horizon.current(Date.new(2026, 9, 8)),
      lines: lines, skipped: {}, skipped_details: {}, as_of: nil,
      allocated_hours: { [100, SEP] => 52.0 },
    )
    by = r.by_contributor_month(c)
    assert_equal 52.0, by[SEP][:allocated_hours]
    assert_equal 176, by[SEP][:capacity_hours]
    assert_in_delta 0.2955, by[SEP][:utilization], 0.0001
    assert_equal 0.0, by[OCT][:allocated_hours]
    assert_equal 0.0, by[OCT][:utilization]
    # Results built without allocated_hours (older cache entries) still work
    assert_equal 0.0, result(lines).by_contributor_month(c)[SEP][:allocated_hours]
  end
end
