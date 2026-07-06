require "test_helper"

class Studios::Snapshots::GradationRowsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    Studio.instance_variable_set(:@all_studios, nil)
    @account = qbo_accounts(:one)
    @studio = Studio.create!(name: "XXIX", mini_name: "xxix", accounting_prefix: "XXIX")
    @fp = ForecastPerson.create!(forecast_id: 9201, email: "a@x.com", first_name: "Aye", last_name: "Person")
    StudioForecastPerson.create!(studio: @studio, forecast_person: @fp)
    # Periods must postdate UTILIZATION_START_AT (2021-06-01)
    @jan = Stacks::Period.new("January, 2024", Date.new(2024, 1, 1), Date.new(2024, 1, 31), :month)
    @feb = Stacks::Period.new("February, 2024", Date.new(2024, 2, 1), Date.new(2024, 2, 29), :month)
  end

  teardown do
    Studio.instance_variable_set(:@all_studios, nil)
  end

  def seed_pnl!(month, income:, cos:, tools:)
    report = QboProfitAndLossReport.find_or_create_by!(
      qbo_account: @account, starts_at: month, ends_at: month.end_of_month
    ) { |r| r.data = {} }
    %w[cash accrual].each do |method|
      [["Revenue - XXIX", income], ["Total COS - XXIX", cos], ["Tools and Subscriptions - XXIX", tools]]
        .each_with_index do |(label, amount), position|
          QboProfitAndLossLineItem.create!(
            qbo_account: @account, qbo_profit_and_loss_report: report,
            starts_at: month, accounting_method: method,
            position: position, label: label, amount: amount
          )
        end
    end
  end

  def seed_utilization!(month, sellable:, billable_map:, time_off: 0, internal: 0, unsold: 0)
    ForecastPersonUtilizationReport.create!(
      forecast_person_id: @fp.id,
      starts_at: month, ends_at: month.end_of_month,
      period_gradation: :month,
      expected_hours_sold: sellable, expected_hours_unsold: unsold,
      actual_hours_sold: billable_map.values.sum,
      actual_hours_internal: internal, actual_hours_time_off: time_off,
      actual_hours_sold_by_rate: billable_map,
      utilization_rate: 0
    )
  end

  test "produces blob-shaped rows with correct P&L, growth, utilization and lead datapoints" do
    seed_pnl!(Date.new(2024, 1, 1), income: 100, cos: 40, tools: 10)
    seed_pnl!(Date.new(2024, 2, 1), income: 150, cos: 40, tools: 10)
    seed_utilization!(Date.new(2024, 1, 1), sellable: 100, billable_map: { "150.0" => 40.0, "0.0" => 10.0 }, time_off: 8, internal: 5, unsold: 20)
    seed_utilization!(Date.new(2024, 2, 1), sellable: 110, billable_map: { "150.0" => 50.0 })

    page = NotionPage.create!(
      notion_id: SecureRandom.uuid,
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]),
      data: { "properties" => {} }
    )
    lead = NotionLead.create!(notion_page_id: page.id, received_at: Date.new(2024, 2, 5))
    NotionLeadStudio.create!(notion_lead: lead, studio: @studio)

    rows = Studios::Snapshots::GradationRows.call(
      studio: @studio, gradation: :month, periods: [@jan, @feb]
    )

    assert_equal 2, rows.length
    jan, feb = rows

    assert_equal "January, 2024", jan[:label]
    assert_equal "01/01/2024", jan[:period_starts_at]
    assert_equal "01/31/2024", jan[:period_ends_at]

    # P&L (prefixed studio: cogs = cos - tools, noi = income - cos)
    d = jan[:cash][:datapoints]
    assert_equal 100.0, d[:income][:value]
    assert_equal 30.0, d[:cost_of_goods_sold][:value]
    assert_equal 10.0, d[:expenses][:value]
    assert_equal 60.0, d[:net_operating_income][:value]
    assert_equal 60.0, d[:profit_margin][:value]
    assert_nil d[:income][:growth] # first period has no prev

    # Feb growth: ((150/100)*100)-100 = 50
    assert_in_delta 50.0, feb[:cash][:datapoints][:income][:growth], 0.001
    assert_in_delta 50.0, feb[:cash][:datapoints][:income_growth][:value], 0.001

    # Utilization (Jan): billable total 50, sellable 100
    assert_equal 100, d[:sellable_hours][:value]
    assert_equal 50.0, d[:billable_hours][:value]
    assert_in_delta 50.0, d[:sellable_hours_sold][:value].to_f, 0.001
    # free hours: rate "0.0" bucket = 10 hrs → 10% of sellable
    assert_in_delta 10.0, d[:free_hours][:value].to_f, 0.001
    assert_equal 10.0, d[:free_hours_count][:value]
    assert_equal 8, d[:time_off][:value]
    assert_equal 5, d[:non_billable_hours][:value]
    assert_equal 20, d[:non_sellable_hours][:value]
    # weighted avg rate: (150*40 + 0*10) / 50 = 120
    assert_in_delta 120.0, d[:average_hourly_rate][:value].to_f, 0.001
    # cost per hour sold: (income - noi) / billable = 40/50
    assert_in_delta 0.8, d[:actual_cost_per_hour_sold][:value].to_f, 0.001

    # Leads: 1 received in Feb, 0 in Jan
    assert_equal 0, d[:lead_count][:value]
    assert_equal 1, feb[:cash][:datapoints][:lead_count][:value]

    # Per-person utilization breakdown keyed by email
    assert_equal ["a@x.com"], jan[:utilization].keys
    assert_equal 8, jan[:utilization]["a@x.com"][:time_off]

    # okrs key exists on both methods (empty hash without OKR rows)
    assert_equal({}, jan[:cash][:okrs])
    assert jan[:accrual].key?(:datapoints)
  end

  test "pre-2021-06 periods still fold utilization from monthly rows (blob parity)" do
    # The stored blob (Studio#utilization_by_period_gradation) has NO date
    # gate: sync_utilization_reports! generates monthly FPUR rows back to
    # 2020-01-01, so a Jan 2021 period carries numeric utilization in the blob
    # even though it predates UTILIZATION_START_AT (2021-06-01). GradationRows
    # must match — a monthly row's mere existence drives utilization.
    seed_utilization!(Date.new(2021, 1, 1), sellable: 80, billable_map: { "150.0" => 40.0 }, time_off: 4, internal: 3, unsold: 12)
    old_period = Stacks::Period.new("January, 2021", Date.new(2021, 1, 1), Date.new(2021, 1, 31), :month)
    refute old_period.has_utilization_data?, "period must predate UTILIZATION_START_AT for this test to be meaningful"

    rows = Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :month, periods: [old_period])
    d = rows.first[:cash][:datapoints]
    assert_equal 80, d[:sellable_hours][:value]
    assert_equal 40.0, d[:billable_hours][:value]
    assert_equal 4, d[:time_off][:value]
    assert_in_delta 150.0, d[:average_hourly_rate][:value].to_f, 0.001
    # Per-person breakdown is populated even for the pre-2021-06 period.
    assert_equal ["a@x.com"], rows.first[:utilization].keys
    assert_equal 4, rows.first[:utilization]["a@x.com"][:time_off]
  end

  test "periods with no monthly utilization rows get nil utilization datapoints" do
    # No FPUR rows seeded at all → empty fold → nil v → nil datapoints and {}
    # breakdown, matching the blob's behavior when no report rows exist.
    barren_period = Stacks::Period.new("January, 2019", Date.new(2019, 1, 1), Date.new(2019, 1, 31), :month)
    rows = Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :month, periods: [barren_period])
    d = rows.first[:cash][:datapoints]
    assert_nil d[:sellable_hours][:value]
    assert_nil d[:billable_hours][:value]
    assert_nil d[:average_hourly_rate][:value]
    assert_equal({}, rows.first[:utilization])
  end

  test "quarter periods fold multiple months" do
    seed_pnl!(Date.new(2024, 1, 1), income: 100, cos: 40, tools: 10)
    seed_pnl!(Date.new(2024, 2, 1), income: 150, cos: 40, tools: 10)
    seed_utilization!(Date.new(2024, 1, 1), sellable: 100, billable_map: { "150.0" => 40.0 })
    seed_utilization!(Date.new(2024, 2, 1), sellable: 110, billable_map: { "150.0" => 50.0, "100.0" => 10.0 })

    q1 = Stacks::Period.new("Q1, 2024", Date.new(2024, 1, 1), Date.new(2024, 3, 31), :quarter)
    rows = Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :quarter, periods: [q1])
    d = rows.first[:cash][:datapoints]

    assert_equal 250.0, d[:income][:value]        # 100 + 150
    assert_equal 170.0, d[:net_operating_income][:value] # 60 + 110
    assert_equal 210, d[:sellable_hours][:value]  # 100 + 110
    assert_equal 100.0, d[:billable_hours][:value] # 40 + 50 + 10
    # rate map merged across months: 150.0 → 90, 100.0 → 10 → weighted avg = (150*90 + 100*10)/100 = 145
    assert_in_delta 145.0, d[:average_hourly_rate][:value].to_f, 0.001
  end

  test "empty project set yields NaN successful_projects (legacy parity)" do
    rows = Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :month, periods: [@jan])
    d = rows.first[:cash][:datapoints]
    assert_equal 0, d[:total_projects][:value]
    assert d[:successful_projects][:value].nan?
    assert d[:successful_proposals][:value].nan?
  end

  test "garden3d reads P&L from exact total-row labels (cogs/noi direct, not derived)" do
    g3d = Studio.create!(name: "garden3d", mini_name: "g3d")
    Studio.instance_variable_set(:@all_studios, nil)
    report = QboProfitAndLossReport.find_or_create_by!(
      qbo_account: @account, starts_at: Date.new(2024, 1, 1), ends_at: Date.new(2024, 1, 31)
    ) { |r| r.data = {} }
    # A section-header "Income" precedes "Total Income" — the exact-label
    # match must pick "Total Income" (200), not the header.
    [["Income", 999], ["Total Income", 200], ["Total Cost of Goods Sold", 70],
     ["Total Expenses", 25], ["Net Operating Income", 130]].each_with_index do |(label, amount), position|
      QboProfitAndLossLineItem.create!(
        qbo_account: @account, qbo_profit_and_loss_report: report,
        starts_at: Date.new(2024, 1, 1), accounting_method: "cash",
        position: position, label: label, amount: amount
      )
    end

    rows = Studios::Snapshots::GradationRows.call(studio: g3d, gradation: :month, periods: [@jan])
    d = rows.first[:cash][:datapoints]
    assert_equal 200.0, d[:income][:value]
    assert_equal 70.0, d[:cost_of_goods_sold][:value]        # read directly, NOT cos - expenses
    assert_equal 25.0, d[:expenses][:value]
    assert_equal 130.0, d[:net_operating_income][:value]     # read directly, NOT income - cos
    assert_in_delta 65.0, d[:profit_margin][:value], 0.001   # 130 / 200 * 100
  end

  test "blank-email person is keyed by first-and-last name in the breakdown" do
    nameless = ForecastPerson.create!(forecast_id: 9301, email: "", first_name: "Nomail", last_name: "Person")
    StudioForecastPerson.create!(studio: @studio, forecast_person: nameless)
    ForecastPersonUtilizationReport.create!(
      forecast_person_id: nameless.id,
      starts_at: Date.new(2024, 1, 1), ends_at: Date.new(2024, 1, 31),
      period_gradation: :month,
      expected_hours_sold: 50, expected_hours_unsold: 0,
      actual_hours_sold: 10, actual_hours_internal: 0, actual_hours_time_off: 3,
      actual_hours_sold_by_rate: { "100.0" => 10.0 }, utilization_rate: 0
    )

    rows = Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :month, periods: [@jan])
    breakdown = rows.first[:utilization]
    assert_equal ["Nomail Person"], breakdown.keys
    assert_equal 3, breakdown["Nomail Person"][:time_off]
  end

  test "successful_proposals is the won-rate over proposals settled in the period" do
    # Two proposals settled in Jan (one won, one not) → 50%; a third settled
    # outside the period is excluded; a settled lead with no proposal_sent is
    # not a proposal at all.
    [
      { received_at: Date.new(2023, 12, 1), proposal_sent_at: Date.new(2023, 12, 15), settled_at: Date.new(2024, 1, 10), won_at: Date.new(2024, 1, 10) },
      { received_at: Date.new(2023, 12, 1), proposal_sent_at: Date.new(2023, 12, 20), settled_at: Date.new(2024, 1, 20), won_at: nil },
      { received_at: Date.new(2023, 12, 1), proposal_sent_at: Date.new(2023, 12, 20), settled_at: Date.new(2024, 2, 20), won_at: Date.new(2024, 2, 20) }, # settled outside Jan
      { received_at: Date.new(2023, 12, 1), proposal_sent_at: nil, settled_at: Date.new(2024, 1, 25), won_at: Date.new(2024, 1, 25) }, # no proposal_sent
    ].each_with_index do |attrs, i|
      page = NotionPage.create!(
        notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
        notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]),
        data: { "properties" => {} }
      )
      lead = NotionLead.create!(notion_page_id: page.id, **attrs)
      NotionLeadStudio.create!(notion_lead: lead, studio: @studio)
    end

    rows = Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :month, periods: [@jan])
    d = rows.first[:cash][:datapoints]
    assert_in_delta 50.0, d[:successful_proposals][:value], 0.001  # 1 won of 2 settled-in-Jan proposals
    assert_equal 2, d[:successful_proposals][:extras][:notion_page_ids].length
  end

  test "P&L gap warning ignores future months (they cannot be synced yet)" do
    cur = Date.today.beginning_of_month
    prev = (Date.today - 1.month).beginning_of_month
    nxt = (Date.today + 1.month).beginning_of_month
    # Span runs into next month (future @through); seed prev + current only.
    span = Stacks::Period.new("span", prev, nxt.end_of_month, :month)
    seed_pnl!(prev, income: 10, cos: 1, tools: 1)
    seed_pnl!(cur, income: 10, cos: 1, tools: 1)

    # Future month (nxt) is absent but must NOT be reported — it can't be synced yet.
    Rails.logger.expects(:warn).with(regexp_matches(/missing P&L months/)).never
    Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :month, periods: [span])
  end

  test "P&L gap warning fires when a syncable past month is missing" do
    cur = Date.today.beginning_of_month
    prev = (Date.today - 1.month).beginning_of_month
    span = Stacks::Period.new("span", prev, cur.end_of_month, :month)
    seed_pnl!(cur, income: 10, cos: 1, tools: 1) # prev deliberately missing

    Rails.logger.expects(:warn).with(regexp_matches(/missing P&L months.*#{Regexp.escape(prev.iso8601)}/)).at_least_once
    Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :month, periods: [span])
  end
end
