require 'test_helper'

class ProjectTrackerMonthlyBudgetTest < ActiveSupport::TestCase
  def tracker!(**attrs)
    pt = ProjectTracker.new({ name: "Retainer (ongoing)" }.merge(attrs))
    pt.save!(validate: false)
    pt
  end

  def with_links!(pt)
    pt.project_tracker_links.create!(name: "MSA", url: "https://x/msa", link_type: :msa)
    pt.project_tracker_links.create!(name: "SOW", url: "https://x/sow", link_type: :sow)
    pt
  end

  # ---- mirroring + validation --------------------------------------------

  test "entering only the low end mirrors it to the high end" do
    pt = ProjectTracker.new(name: "X", monthly_budget_low_end: 6000)
    pt.valid?
    assert_equal 6000, pt.monthly_budget_high_end
    assert pt.monthly_budget?
  end

  test "entering only the high end mirrors it to the low end" do
    pt = ProjectTracker.new(name: "X", monthly_budget_high_end: 79_400)
    pt.valid?
    assert_equal 79_400, pt.monthly_budget_low_end
  end

  test "a range keeps both ends and rejects low above high" do
    pt = ProjectTracker.new(name: "X", monthly_budget_low_end: 5000, monthly_budget_high_end: 8000)
    pt.valid?
    assert_equal [5000, 8000], [pt.monthly_budget_low_end, pt.monthly_budget_high_end]
    assert_empty pt.errors[:monthly_budget_low_end]

    bad = ProjectTracker.new(name: "X", monthly_budget_low_end: 9000, monthly_budget_high_end: 8000)
    bad.valid?
    assert_not_empty bad.errors[:monthly_budget_low_end]
  end

  test "zero and negative monthly budgets are rejected" do
    zero = ProjectTracker.new(name: "X", monthly_budget_low_end: 0)
    zero.valid?
    assert_not_empty zero.errors[:monthly_budget_low_end]

    neg = ProjectTracker.new(name: "X", monthly_budget_high_end: -500)
    neg.valid?
    assert_not_empty neg.errors[:monthly_budget_high_end]
  end

  test "no monthly budget stays nil on both sides" do
    pt = ProjectTracker.new(name: "X")
    pt.valid?
    assert_nil pt.monthly_budget_low_end
    assert_nil pt.monthly_budget_high_end
    assert_not pt.monthly_budget?
  end

  test "the overall band is untouched by the monthly budget" do
    pt = ProjectTracker.new(name: "X", budget_low_end: 10_000, budget_high_end: 20_000,
                            monthly_budget_low_end: 4000)
    pt.valid?
    assert pt.overall_budget?
    assert pt.monthly_budget?
    assert_equal 4000, pt.monthly_budget_high_end
  end

  # ---- update_details! (the MCP path) --------------------------------------

  test "update_details! sets a fixed monthly budget from one end and the new link types" do
    pt = with_links!(tracker!)
    pt.update_details!(monthly_budget_low_end: 6000,
                       twist_channel_url: "https://twist.com/a/1/ch/2",
                       notion_homepage_url: "https://app.notion.com/p/home")
    pt.reload
    assert_equal 6000, pt.monthly_budget_low_end
    assert_equal 6000, pt.monthly_budget_high_end
    assert_equal "https://twist.com/a/1/ch/2", pt.project_tracker_links.find { |l| l.twist_channel? }.url
    assert_equal "https://app.notion.com/p/home", pt.project_tracker_links.find { |l| l.notion_homepage? }.url
  end

  test "update_details! with one end on an EXISTING budget replaces it with a fixed budget" do
    pt = with_links!(tracker!(monthly_budget_low_end: 5000, monthly_budget_high_end: 8000))
    pt.update_details!(monthly_budget_low_end: 7000)
    assert_equal [7000, 7000], [pt.reload.monthly_budget_low_end, pt.monthly_budget_high_end]

    pt.update_details!(monthly_budget_high_end: 4000)
    assert_equal [4000, 4000], [pt.reload.monthly_budget_low_end, pt.monthly_budget_high_end]
  end

  test "update_details! with both ends sets a range, and clear_monthly_budget removes it" do
    pt = with_links!(tracker!(monthly_budget_low_end: 5000, monthly_budget_high_end: 5000))
    pt.update_details!(monthly_budget_low_end: 6000, monthly_budget_high_end: 9000)
    assert_equal [6000, 9000], [pt.reload.monthly_budget_low_end, pt.monthly_budget_high_end]

    pt.update_details!(clear_monthly_budget: true)
    assert_nil pt.reload.monthly_budget_low_end
    assert_nil pt.monthly_budget_high_end
    assert_not pt.monthly_budget?
  end

  test "update_details! refuses clear_monthly_budget combined with a value" do
    pt = with_links!(tracker!(monthly_budget_low_end: 5000, monthly_budget_high_end: 5000))
    assert_raises(ArgumentError) { pt.update_details!(clear_monthly_budget: true, monthly_budget_low_end: 7000) }
    assert_equal 5000, pt.reload.monthly_budget_low_end
  end

  test "link URLs are stripped before validation and storage" do
    pt = tracker!
    link = pt.project_tracker_links.create!(name: "T", url: "  https://twist.com/a/1/ch/2  ", link_type: :twist_channel)
    assert_equal "https://twist.com/a/1/ch/2", link.reload.url
    empty_userinfo = pt.project_tracker_links.build(name: "T", url: "https://@x.example/", link_type: :other)
    assert_not empty_userinfo.valid?
  end

  test "update_details! leaves the monthly budget alone when neither end is passed" do
    pt = with_links!(tracker!(monthly_budget_low_end: 5000, monthly_budget_high_end: 8000))
    pt.update_details!(name: "Renamed (ongoing)")
    assert_equal [5000, 8000], [pt.reload.monthly_budget_low_end, pt.monthly_budget_high_end]
  end

  # ---- weekly_ship_block ---------------------------------------------------

  def stub_money(pt, income:, spend:, hours_7d:, spend_7d:)
    pt.stubs(:income).returns(income)
    pt.stubs(:spend).returns(spend)
    pt.stubs(:hours_trailing_7_days).returns(hours_7d.to_f)
    pt.stubs(:trailing_7_days_value).returns(spend_7d)
  end

  test "block for an overall band prints total spend to date and both ends" do
    pt = tracker!(name: "Storm King Design", budget_low_end: 42_000, budget_high_end: 48_000)
    stub_money(pt, income: 17_975, spend: 24_350, hours_7d: 15, spend_7d: 2575)

    assert_equal <<~TXT.chomp, pt.weekly_ship_block
      ⏳ Hours Progress
      Trailing 7 days: 15.0 hours ($2,575.00)

      💹 Budgetary Progress
      Invoiced: $17,975.00
      Spend this Month: $6,375.00
      Total Spend to Date: $24,350.00
      Budget Low End: $42,000.00
      Budget High End: $48,000.00
    TXT
  end

  test "block for a fixed overall budget prints a single Budget line" do
    pt = tracker!(name: "USB Club", budget_low_end: 42_200, budget_high_end: 42_200)
    stub_money(pt, income: 10_000, spend: 12_500, hours_7d: 8.5, spend_7d: 1275)

    assert_includes pt.weekly_ship_block, "Total Spend to Date: $12,500.00\nBudget: $42,200.00"
    assert_not_includes pt.weekly_ship_block, "Budget Low End"
  end

  test "block for a monthly-budget retainer omits total spend to date and the band" do
    pt = tracker!(name: "Harvey Staff Augmentation", monthly_budget_low_end: 79_400, monthly_budget_high_end: 79_400)
    stub_money(pt, income: 425_700, spend: 474_945, hours_7d: 75, spend_7d: 13_765)

    assert_equal <<~TXT.chomp, pt.weekly_ship_block
      ⏳ Hours Progress
      Trailing 7 days: 75.0 hours ($13,765.00)

      💹 Budgetary Progress
      Invoiced: $425,700.00
      Spend this Month: $49,245.00
      Monthly Budget: $79,400.00
    TXT
  end

  test "block for a monthly range prints both monthly ends" do
    pt = tracker!(monthly_budget_low_end: 5000, monthly_budget_high_end: 8000)
    stub_money(pt, income: 100, spend: 600, hours_7d: 2, spend_7d: 300)

    assert_includes pt.weekly_ship_block, "Monthly Budget Low End: $5,000.00\nMonthly Budget High End: $8,000.00"
    assert_not_includes pt.weekly_ship_block, "Total Spend to Date"
  end

  test "block with both a monthly budget and an overall band prints both" do
    pt = tracker!(budget_low_end: 16_050, budget_high_end: 35_670, monthly_budget_low_end: 6000, monthly_budget_high_end: 6000)
    stub_money(pt, income: 29_302.5, spend: 32_715, hours_7d: 12.67, spend_7d: 2100)

    block = pt.weekly_ship_block
    assert_includes block, "Trailing 7 days: 12.7 hours ($2,100.00)"
    assert_includes block, "Monthly Budget: $6,000.00\nTotal Spend to Date: $32,715.00\nBudget Low End: $16,050.00\nBudget High End: $35,670.00"
  end

  test "block with no budgets at all stops after Spend this Month" do
    pt = tracker!(name: "Salt & Stone (ongoing)")
    stub_money(pt, income: 380_564.25, spend: 383_489.25, hours_7d: 12.5, spend_7d: 1875)

    block = pt.weekly_ship_block
    assert block.end_with?("Spend this Month: $2,925.00"), block
    assert_not_includes block, "Total Spend to Date"
    assert_not_includes block, "Budget:"
    assert_not_includes block, "Budget Low End"
    assert_not_includes block, "Monthly Budget"
  end

  test "block carries no HTML-special characters (it is embedded raw in a script tag)" do
    pt = tracker!(budget_low_end: 1000, budget_high_end: 2000, monthly_budget_low_end: 500, monthly_budget_high_end: 900)
    stub_money(pt, income: 100, spend: 600, hours_7d: 2, spend_7d: 300)
    assert_no_match(/[<>&"']/, pt.weekly_ship_block)
  end

  test "weekly_ship_block accepts precomputed numbers so callers compute the live figures once" do
    pt = tracker!(monthly_budget_low_end: 6000, monthly_budget_high_end: 6000)
    pt.expects(:hours_trailing_7_days).never
    numbers = { hours_7d: 3.0, spend_7d: 450.0, invoiced: 100.0, running_spend: 50.0, total_spend: 150.0 }
    assert_includes pt.weekly_ship_block(numbers), "Trailing 7 days: 3.0 hours ($450.00)"
  end

  # ---- link URL validation ---------------------------------------------------

  test "links must be anchored http(s) URLs with a host and no credentials" do
    pt = tracker!
    ok = pt.project_tracker_links.build(name: "T", url: "https://twist.com/a/1/ch/2", link_type: :twist_channel)
    assert ok.valid?, ok.errors.full_messages.inspect

    [
      "javascript:alert(1)//https://x",
      "data:text/html,https://",
      "ftp://example.com/x",
      "not a url",
      "https://",
      "https://user:pass@staging.example.com/",
    ].each do |bad_url|
      link = pt.project_tracker_links.build(name: "T", url: bad_url, link_type: :other)
      assert_not link.valid?, "expected #{bad_url.inspect} to be rejected"
    end
  end
end
