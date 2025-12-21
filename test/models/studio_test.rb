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
    u = studio.utilization_for_period(jan, studio.forecast_people)[forecast_person]

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
    u = studio.utilization_for_period(jan, studio.forecast_people)[forecast_person]

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
    u = studio.utilization_for_period(jan, studio.forecast_people)[forecast_person]

    assert u[:sellable] == 0
    assert u[:non_sellable] == 0
  end
end