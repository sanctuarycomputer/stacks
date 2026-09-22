require 'test_helper'

class ProjectTrackerWeeklyShipSummaryTest < ActiveSupport::TestCase
  def tracker!(name:, **attrs)
    pt = ProjectTracker.new({ name: name }.merge(attrs))
    pt.save!(validate: false)
    pt
  end

  def stub_money(pt, income:, spend:, hours_7d:, spend_7d:)
    pt.stubs(:income).returns(income)
    pt.stubs(:spend).returns(spend)
    pt.stubs(:hours_trailing_7_days).returns(hours_7d.to_f)
    pt.stubs(:trailing_7_days_value).returns(spend_7d)
  end

  test "summary sums hours, money, and both budget ends across banded trackers" do
    design = tracker!(name: "Storm King Design", budget_low_end: 42_000, budget_high_end: 48_000)
    dev = tracker!(name: "Storm King Development", budget_low_end: 63_692, budget_high_end: 70_062)
    stub_money(design, income: 17_975, spend: 24_350, hours_7d: 14, spend_7d: 2400)
    stub_money(dev, income: 7_492.5, spend: 13_431.25, hours_7d: 9.5, spend_7d: 1222.5)

    n = ProjectTracker.weekly_ship_summary([design, dev])
    assert_equal 23.5, n[:hours_7d]
    assert_equal 3622.5, n[:spend_7d]
    assert_equal 25_467.5, n[:invoiced]
    assert_in_delta 12_313.75, n[:running_spend], 0.001
    assert_in_delta 37_781.25, n[:total_spend], 0.001
    assert_equal 105_692.0, n[:budget_low_end]
    assert_equal 118_062.0, n[:budget_high_end]
    assert_nil n[:monthly_budget_low_end]

    assert_equal <<~TXT.chomp, ProjectTracker.render_weekly_ship_block(n)
      ⏳ Hours Progress
      Trailing 7 days: 23.5 hours ($3,622.50)

      💹 Budgetary Progress
      Invoiced: $25,467.50
      Spend this Month: $12,313.75
      Total Spend to Date: $37,781.25
      Budget Low End: $105,692.00
      Budget High End: $118,062.00
    TXT
  end

  test "a band prints only when every tracker has one; a monthly budget likewise" do
    banded = tracker!(name: "A", budget_low_end: 10_000, budget_high_end: 12_000)
    retainer = tracker!(name: "B (ongoing)", monthly_budget_low_end: 6000, monthly_budget_high_end: 6000)
    stub_money(banded, income: 1000, spend: 1500, hours_7d: 2, spend_7d: 300)
    stub_money(retainer, income: 2000, spend: 2600, hours_7d: 4, spend_7d: 600)

    n = ProjectTracker.weekly_ship_summary([banded, retainer])
    assert_nil n[:budget_low_end]
    assert_nil n[:monthly_budget_low_end]
    block = ProjectTracker.render_weekly_ship_block(n)
    assert block.end_with?("Spend this Month: $1,100.00"), block
    assert_not_includes block, "Total Spend to Date"
    assert_not_includes block, "Monthly Budget"
  end

  test "two fixed monthly budgets sum into one Monthly Budget line" do
    a = tracker!(name: "A (retainer)", monthly_budget_low_end: 4000, monthly_budget_high_end: 4000)
    b = tracker!(name: "B (retainer)", monthly_budget_low_end: 2000, monthly_budget_high_end: 2000)
    stub_money(a, income: 100, spend: 300, hours_7d: 1, spend_7d: 100)
    stub_money(b, income: 100, spend: 200, hours_7d: 1, spend_7d: 100)

    block = ProjectTracker.render_weekly_ship_block(ProjectTracker.weekly_ship_summary([a, b]))
    assert_includes block, "Monthly Budget: $6,000.00"
    assert_not_includes block, "Monthly Budget Low End"
  end

  test "a single tracker's summary renders the same block as the instance method" do
    pt = tracker!(name: "Solo", budget_low_end: 5000, budget_high_end: 5000)
    stub_money(pt, income: 1000, spend: 1800, hours_7d: 3, spend_7d: 450)
    assert_equal pt.weekly_ship_block, ProjectTracker.render_weekly_ship_block(ProjectTracker.weekly_ship_summary([pt]))
    assert_includes pt.weekly_ship_block, "Budget: $5,000.00"
  end

  test "weeks_left mirrors the tracker page's reference rules" do
    base = { hours_7d: 1, spend_7d: 1000.0, invoiced: 0, running_spend: 0 }
    under = base.merge(total_spend: 5000.0, budget_low_end: 10_000.0, budget_high_end: 12_000.0)
    assert_equal 5.0, ProjectTracker.weekly_ship_weeks_left(under)
    at_low = base.merge(total_spend: 10_000.0, budget_low_end: 10_000.0, budget_high_end: 12_000.0)
    assert_equal 0.0, ProjectTracker.weekly_ship_weeks_left(at_low)
    between = base.merge(total_spend: 11_000.0, budget_low_end: 10_000.0, budget_high_end: 12_000.0)
    assert_equal 1.0, ProjectTracker.weekly_ship_weeks_left(between)
    over = base.merge(total_spend: 13_000.0, budget_low_end: 10_000.0, budget_high_end: 12_000.0)
    assert_nil ProjectTracker.weekly_ship_weeks_left(over)
    no_band = base.merge(total_spend: 500.0, budget_low_end: nil, budget_high_end: nil)
    assert_nil ProjectTracker.weekly_ship_weeks_left(no_band)
    no_pace = under.merge(spend_7d: 0.0)
    assert_nil ProjectTracker.weekly_ship_weeks_left(no_pace)
  end

  test "summary refuses an empty list" do
    assert_raises(ArgumentError) { ProjectTracker.weekly_ship_summary([]) }
  end
end
