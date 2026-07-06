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

  test "periods predating utilization data get nil utilization datapoints" do
    old_period = Stacks::Period.new("January, 2021", Date.new(2021, 1, 1), Date.new(2021, 1, 31), :month)
    rows = Studios::Snapshots::GradationRows.call(studio: @studio, gradation: :month, periods: [old_period])
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
end
