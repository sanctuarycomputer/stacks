require 'test_helper'

class StudioTest < ActiveSupport::TestCase
  test "a five day worker effects expected_utilization" do
    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })
    forecast_person = ForecastPerson.create!({
      id: "999",
      first_name: "Hugh",
      last_name: "Francis",
      email: "hugh@sanctuary.computer",
      archived: false,
      roles: ["Sanctuary Computer"],
      updated_at: Date.today,
    })
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    StudioMembership.create!({
      studio: studio,
      admin_user: admin_user,
      started_at: admin_user.created_at
    })
    ftp = FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2021, 1, 1),
      ended_at: Date.new(2021, 12, 31),
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })
    admin_user.full_time_periods.reload

    ForecastPerson.all.each{ |fp| fp.sync_utilization_reports! }
    jan = Stacks::Period.new("January 2020", Date.new(2021, 6, 1), Date.new(2021, 6, 30))
    u = studio.utilization_for_period(jan)[forecast_person]

    assert (u[:sellable] / (u[:sellable] + u[:non_sellable])) == ftp.expected_utilization
  end

  test "a four day worker effects expected_utilization" do
    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })
    forecast_person = ForecastPerson.create!({
      id: "999",
      first_name: "Hugh",
      last_name: "Francis",
      email: "hugh@sanctuary.computer",
      archived: false,
      roles: ["Sanctuary Computer"],
      updated_at: Date.today,
    })
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    StudioMembership.create!({
      studio: studio,
      admin_user: admin_user,
      started_at: admin_user.created_at
    })
    ftp = FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2021, 1, 1),
      ended_at: Date.new(2021, 12, 31),
      contributor_type: Enum::ContributorType::FOUR_DAY,
      expected_utilization: 0.6
    })
    admin_user.full_time_periods.reload

    ForecastPerson.all.each{ |fp| fp.sync_utilization_reports! }

    jan = Stacks::Period.new("January 2020", Date.new(2021, 6, 1), Date.new(2021, 6, 30))
    u = studio.utilization_for_period(jan)[forecast_person]

    assert (u[:sellable] / (u[:sellable] + u[:non_sellable])) == ftp.expected_utilization
  end

  test "a variable hours worker does NOT effect expected_utilization" do
    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })
    forecast_person = ForecastPerson.create!({
      id: "999",
      first_name: "Hugh",
      last_name: "Francis",
      email: "hugh@sanctuary.computer",
      archived: false,
      roles: ["Sanctuary Computer"],
      updated_at: Date.today,
    })
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    StudioMembership.create!({
      studio: studio,
      admin_user: admin_user,
      started_at: admin_user.created_at
    })
    ftp = FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2021, 1, 1),
      ended_at: Date.new(2021, 12, 31),
      contributor_type: Enum::ContributorType::VARIABLE_HOURS,
      expected_utilization: 0.6
    })
    admin_user.full_time_periods.reload

    ForecastPerson.all.each{ |fp| fp.sync_utilization_reports! }
    jan = Stacks::Period.new("January 2020", Date.new(2021, 6, 1), Date.new(2021, 6, 30))
    u = studio.utilization_for_period(jan)[forecast_person]

    assert u[:sellable] == 0
    assert u[:non_sellable] == 0
  end

  test "members_active_on returns studio members active on the date" do
    studio = Studio.create!(name: "Alpha", mini_name: "alpha")
    au = AdminUser.create!(email: "m@sanctuary.computer", password: "password12345", password_confirmation: "password12345")
    StudioMembership.create!(studio: studio, admin_user: au, started_at: Date.new(2026, 1, 1), ended_at: nil)

    assert_includes studio.members_active_on(Date.new(2026, 6, 1)), au
    assert_not_includes studio.members_active_on(Date.new(2025, 1, 1)), au # before membership
  end

  test "key_datapoints_for_period includes all four client KPI keys with correct units" do
    studio = Studio.create!(name: "garden3d", mini_name: "g3d", accounting_prefix: "")

    pnl = { income: 0.0, cost_of_goods_sold: 0.0, expenses: 0.0, net_operating_income: 0.0 }
    studio.stubs(:profit_and_loss_for_period).returns(pnl)

    period = Stacks::Period.new("Jan 2025", Date.new(2025, 1, 1), Date.new(2025, 1, 31))
    cr = Stacks::ClientRevenue.new(studio, [studio], [])

    data = studio.key_datapoints_for_period(
      period,
      nil,
      "cash",
      [studio],
      [],
      {},
      {},
      {},
      {},
      cr
    )

    # All four new KPI keys must be present
    assert data.key?(:average_client_lifetime_value), "expected :average_client_lifetime_value"
    assert data.key?(:average_client_tenure),         "expected :average_client_tenure"
    assert data.key?(:client_revenue_concentration),  "expected :client_revenue_concentration"
    assert data.key?(:forecasted_sales_revenue),      "expected :forecasted_sales_revenue"

    # Units
    assert_equal :usd,        data[:average_client_lifetime_value][:unit]
    assert_equal :count,      data[:average_client_tenure][:unit]
    assert_equal :percentage, data[:client_revenue_concentration][:unit]
    assert_equal :usd,        data[:forecasted_sales_revenue][:unit]

    # With no trackers and no leads, LTV is 0
    assert_equal 0, data[:average_client_lifetime_value][:value]

    # extras keys present
    assert data[:average_client_lifetime_value][:extras].key?(:client_count)
    assert data[:average_client_lifetime_value][:extras].key?(:skipped_tracker_count)
    assert data[:average_client_tenure][:extras].key?(:client_count)
    assert data[:client_revenue_concentration][:extras].key?(:top_client_name)
    assert data[:client_revenue_concentration][:extras].key?(:top_client_amount)
    assert data[:client_revenue_concentration][:extras].key?(:total_revenue)
    assert data[:client_revenue_concentration][:extras].key?(:skipped_tracker_count)
    assert data[:forecasted_sales_revenue][:extras].key?(:open_lead_count)
    assert data[:forecasted_sales_revenue][:extras].key?(:budgeted_lead_count)
  end
end
