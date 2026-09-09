require "test_helper"

class ContributorProjections::HorizonTest < ActiveSupport::TestCase
  test "current covers this month plus MONTHS_AHEAD following months" do
    h = ContributorProjections::Horizon.current(Date.new(2026, 9, 8))
    assert_equal Date.new(2026, 9, 1), h.starts_at
    assert_equal Date.new(2026, 12, 31), h.ends_at
    assert_equal 4, h.months.size
    assert_equal [Date.new(2026, 9, 1), Date.new(2026, 10, 1), Date.new(2026, 11, 1), Date.new(2026, 12, 1)], h.month_keys
    assert_equal "September, 2026", h.months.first.label
    assert_equal Date.new(2026, 9, 30), h.months.first.ends_at
    assert_equal :month, h.months.first.gradation
  end

  test "current crosses a year boundary" do
    h = ContributorProjections::Horizon.current(Date.new(2026, 11, 20))
    assert_equal [Date.new(2026, 11, 1), Date.new(2026, 12, 1), Date.new(2027, 1, 1), Date.new(2027, 2, 1)], h.month_keys
    assert_equal Date.new(2027, 2, 28), h.ends_at
  end

  test "stale? is true for nil and for anything older than STALE_AFTER_DAYS" do
    today = Date.new(2026, 9, 8)
    assert ContributorProjections.stale?(nil, today: today)
    assert ContributorProjections.stale?(DateTime.new(2026, 9, 5, 12), today: today)
    assert_not ContributorProjections.stale?(DateTime.new(2026, 9, 6, 12), today: today)
    assert_not ContributorProjections.stale?(DateTime.new(2026, 9, 8, 1), today: today)
  end

  test "runn_synced_at reads through System.first" do
    s = System.first || System.create!(settings: {})
    s.update!(runn_synced_at: DateTime.new(2026, 9, 7, 3))
    assert_equal DateTime.new(2026, 9, 7, 3).to_i, ContributorProjections.runn_synced_at.to_i
  end

  test "Line is keyword-initialized with every member" do
    l = ContributorProjections::Line.new(kind: :individual_contributor, ledger_id: 1, enterprise_id: 2, contributor_id: 3,
                                         project_tracker_id: 4, project_tracker_name: "T", hours: 10.0, rate: 200.0, amount: 1080.0,
                                         description: "d", tentative: false, rate_mismatch: false, month: Date.new(2026, 9, 1))
    assert_equal 1080.0, l.amount
    assert_equal Date.new(2026, 9, 1), l.month
  end
end
