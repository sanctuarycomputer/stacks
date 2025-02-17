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

  test "#core_members_active_on respects the current studio membership" do
    sanctu = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    xxix = Studio.create!({
      name: "XXIX",
      accounting_prefix: "Design",
      mini_name: "xxix"
    })

    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_3
    })

    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.today - 10.days,
      ended_at: nil,
      contributor_type: :five_day,
      expected_utilization: 0.8
    })

    StudioMembership.create!({
      admin_user: admin_user,
      studio: sanctu,
      started_at: Date.today - 10.days,
      ended_at: Date.yesterday,
    })

    StudioMembership.create!({
      admin_user: admin_user,
      studio: xxix,
      started_at: Date.today,
      ended_at: nil,
    })

    assert_equal sanctu.core_members_active_on(Date.yesterday - 1.day).first, admin_user
    assert_nil sanctu.core_members_active_on(Date.today).first

    assert_nil xxix.core_members_active_on(Date.yesterday - 1.day).first
    assert_equal xxix.core_members_active_on(Date.today).first, admin_user
  end

  test "#studio_members_that_left_during_period respects the current studio membership" do
    sanctu = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    xxix = Studio.create!({
      name: "XXIX",
      accounting_prefix: "Design",
      mini_name: "xxix"
    })

    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_3
    })

    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.today - 10.days,
      ended_at: Date.today + 10.days,
      contributor_type: :five_day,
      expected_utilization: 0.8
    })

    StudioMembership.create!({
      admin_user: admin_user,
      studio: sanctu,
      started_at: Date.today - 10.days,
      ended_at: Date.yesterday,
    })

    StudioMembership.create!({
      admin_user: admin_user,
      studio: xxix,
      started_at: Date.today,
      ended_at: nil,
    })

    period_switching_studios = Stacks::Period.new("Period switching studios", Date.today - 2.days, Date.today + 2.days)
    assert_equal sanctu.studio_members_that_left_during_period(period_switching_studios).first, admin_user
    assert_nil xxix.studio_members_that_left_during_period(period_switching_studios).first

    period_quitting = Stacks::Period.new("Period quitting", Date.today + 8.days, Date.today + 12.days)
    assert_nil sanctu.studio_members_that_left_during_period(period_quitting).first
    assert_equal xxix.studio_members_that_left_during_period(period_quitting).first, admin_user
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
      admin_user: user_one,
      started_at: user_one.created_at
    })

    StudioMembership.create!({
      studio: studio,
      admin_user: user_two,
      started_at: user_two.created_at
    })

    StudioMembership.create!({
      studio: studio,
      admin_user: user_three,
      started_at: user_three.created_at
    })

    StudioMembership.create!({
      studio: studio,
      admin_user: user_four,
      started_at: user_four.created_at
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

  test "it can find all of the studio members active during a given range" do
    studio, g3d = make_studio!

    # Chad quit in May
    chad = make_admin_user!(studio, Date.new(2020, 1, 1), Date.new(2020, 5, 1))
    # Tonya started after Chad but did not quite
    tonya = make_admin_user!(g3d, Date.new(2021, 1, 1), nil, "tonya@thoughtbot.com")

    # g3d finds both Chad and Tonya
    assert_includes(
      g3d.core_members_active_during_range(Date.new(2020, 1, 1), Date.today),
      chad
    )
    assert_includes(
      g3d.core_members_active_during_range(Date.new(2020, 1, 1), Date.today),
      tonya
    )

    # Tonya isn't a member of the studio though
    assert_includes(
      studio.core_members_active_during_range(Date.new(2020, 1, 1), Date.today),
      chad
    )
    refute_includes(
      studio.core_members_active_during_range(Date.new(2020, 1, 1), Date.today),
      tonya
    )

    # g3d Tonya doesn't join until 2021
    assert_includes(
      g3d.core_members_active_during_range(Date.new(2020, 1, 1), Date.new(2020, 12, 31)),
      chad
    )
    refute_includes(
      g3d.core_members_active_during_range(Date.new(2020, 1, 1), Date.new(2020, 12, 31)),
      tonya
    )
  end
end
