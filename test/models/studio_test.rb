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
      roles: [],
      updated_at: Date.today,
    })
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    StudioMembership.create!({
      studio: studio,
      admin_user: admin_user
    })
    ftp = FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2021, 1, 1),
      ended_at: Date.new(2021, 12, 31),
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })
    admin_user.full_time_periods.reload

    jan = Stacks::Period.new("January 2020", Date.new(2021, 6, 1), Date.new(2021, 6, 30))
    u = studio.utilization_for_period(jan, [studio])[forecast_person]

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
      roles: [],
      updated_at: Date.today,
    })
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    StudioMembership.create!({
      studio: studio,
      admin_user: admin_user
    })
    ftp = FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2021, 1, 1),
      ended_at: Date.new(2021, 12, 31),
      contributor_type: Enum::ContributorType::FOUR_DAY,
      expected_utilization: 0.6
    })
    admin_user.full_time_periods.reload

    jan = Stacks::Period.new("January 2020", Date.new(2021, 6, 1), Date.new(2021, 6, 30))
    u = studio.utilization_for_period(jan, [studio])[forecast_person]

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
      roles: [],
      updated_at: Date.today,
    })
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    StudioMembership.create!({
      studio: studio,
      admin_user: admin_user
    })
    ftp = FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2021, 1, 1),
      ended_at: Date.new(2021, 12, 31),
      contributor_type: Enum::ContributorType::VARIABLE_HOURS,
      expected_utilization: 0.6
    })
    admin_user.full_time_periods.reload

    jan = Stacks::Period.new("January 2020", Date.new(2021, 6, 1), Date.new(2021, 6, 30))
    u = studio.utilization_for_period(jan, [studio])[forecast_person]

    assert u[:sellable] == 0
    assert u[:non_sellable] == 0
  end

  test "#skill_levels_on returns the expected values" do
    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    user_one = AdminUser.create!({
      email: "senior_3a@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_3
    })

    user_two = AdminUser.create!({
      email: "senior_3b@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_3
    })

    user_three = AdminUser.create!({
      email: "senior_1@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_1
    })

    user_four = AdminUser.create!({
      email: "junior_1@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :junior_1
    })

    FullTimePeriod.create!({
      admin_user: user_one,
      started_at: Date.yesterday,
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    FullTimePeriod.create!({
      admin_user: user_two,
      started_at: Date.yesterday,
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    FullTimePeriod.create!({
      admin_user: user_three,
      started_at: Date.yesterday,
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    FullTimePeriod.create!({
      admin_user: user_four,
      started_at: Date.yesterday,
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    StudioMembership.create!({
      studio: studio,
      admin_user: user_one
    })

    StudioMembership.create!({
      studio: studio,
      admin_user: user_two
    })

    StudioMembership.create!({
      studio: studio,
      admin_user: user_three
    })

    StudioMembership.create!({
      studio: studio,
      admin_user: user_four
    })

    levels = studio.skill_levels_on(Date.today)

    assert_equal({
      "J1" => 1,
      "J2" => 0,
      "J3" => 0,
      "ML1" => 0,
      "ML2" => 0,
      "ML3" => 0,
      "EML1" => 0,
      "EML2" => 0,
      "EML3" => 0,
      "S1" => 1,
      "S2" => 0,
      "S3" => 2,
      "S4" => 0,
      "L1" => 0,
      "L2" => 0
    }, levels)
  end
end
