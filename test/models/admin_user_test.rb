require 'test_helper'

class AdminUserTest < ActiveSupport::TestCase
  test "My PSU is calculated correctly, even in the future" do
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })
    admin_user.full_time_periods.reload

    # User had not started their employment yet
    assert admin_user.psu_earned_by(Date.new(2019, 1, 1)) == nil

    # User has completed 6 full months
    assert admin_user.psu_earned_by(Date.new(2020, 5, 31)) == 4
    assert admin_user.psu_earned_by(Date.new(2020, 6, 1)) == 5

    # They're about to hit 12 PSU...
    assert admin_user.psu_earned_by(Date.new(2020, 12, 31)) == 11
    assert admin_user.psu_earned_by(Date.new(2021, 1, 1)) == 12

    # BUT! User ended their employment before their 12th PSU clicked over
    admin_user.full_time_periods.first.update!(ended_at: Date.new(2020, 12, 31))
    # They forfeited their PSU, so now it's nil
    assert admin_user.psu_earned_by(Date.new(2021, 1, 1)) == nil
  end

  test "If I had a break in my employment, I forfeit the remainder of my unearnt PSU, even if I resume employment later" do
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 1, 1),
      ended_at: Date.new(2020, 12, 31),
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2021, 6, 5),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })
    admin_user.full_time_periods.reload

    # User had not started their employment yet
    assert admin_user.psu_earned_by(Date.new(2019, 1, 1)) == nil

    # User earns PSU like normal
    assert admin_user.psu_earned_by(Date.new(2020, 2, 1)) == 1

    # User is not currently employed at this point, they've forfeited PSU
    assert admin_user.psu_earned_by(Date.new(2021, 1, 1)) == nil

    # User is now employed again, but their new anchor date is the 5th of the month
    # so this extra day did not incur an additive PSU
    assert admin_user.psu_earned_by(Date.new(2021, 6, 6)) == 11

    # User has resumed earning PSU with a different anchor date
    assert admin_user.psu_earned_by(Date.new(2021, 7, 4)) == 11
    assert admin_user.psu_earned_by(Date.new(2021, 7, 5)) == 12
  end

  test "If my PSU earn rate changed on the anchor date, but I did not have a break in my employment, the previous period is completed" do
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 1, 1),
      ended_at: Date.new(2020, 12, 31),
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2021, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FOUR_DAY,
      expected_utilization: 0.8
    })
    admin_user.full_time_periods.reload

    assert admin_user.psu_earned_by(Date.new(2020, 12, 31)) == 11
    assert admin_user.psu_earned_by(Date.new(2021, 1, 1)) == 12
    assert admin_user.psu_earned_by(Date.new(2021, 2, 1)) == 12.8
  end

  test "If my PSU earn rate changed on a DIFFERENT date to the anchor date, but I did not have a break in my employment, a remainder is added" do
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 1, 1),
      ended_at: Date.new(2020, 12, 15),
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 12, 16),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FOUR_DAY,
      expected_utilization: 0.8
    })
    admin_user.full_time_periods.reload

    admin_user.psu_earned_by(Date.new(2020, 12, 15)) == 11
    assert(
      admin_user.psu_earned_by(Date.new(2020, 12, 16)) > 11 &&
      admin_user.psu_earned_by(Date.new(2020, 12, 16)) < 12
    )
  end

  test "If I have a contiguous PSU earn rate over two+ full_time_periods, it is treated as a single PSU earning period" do
    admin_user = AdminUser.create!({
      email: "hugh@sanctuary.computer",
      password: "passw0rd",
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 1, 1),
      ended_at: Date.new(2020, 12, 15),
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 12, 16),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.2 # Utilization is the only thing that changed on the 16th of December
    })
    admin_user.full_time_periods.reload

    # Anchor date has not changed!
    assert admin_user.psu_earned_by(Date.new(2020, 12, 31)) == 11
    assert admin_user.psu_earned_by(Date.new(2021, 1, 1)) == 12
  end

  test "#met_associates_skill_band_requirement_at when the user has an archived review exceeding the band" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    target_date = 5.days.ago

    user.reviews.create!({
      archived_at: target_date,
      finalization: Finalization.new({
        workspace: Workspace.new({
          status: "complete"
        })
      })
    })

    Review.any_instance.expects(:total_points).returns(650)

    assert_in_delta(
      target_date,
      user.met_associates_skill_band_requirement_at,
      1.second
    )
  end

  test "#met_associates_skill_band_requirement_at when the user has an archived review that does not exceed the band" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    target_date = 5.days.ago

    user.reviews.create!({
      archived_at: target_date,
      finalization: Finalization.new({
        workspace: Workspace.new({
          status: "complete"
        })
      })
    })

    Review.any_instance.expects(:total_points).returns(400)

    assert_nil(user.met_associates_skill_band_requirement_at)
  end

  test "#met_associates_skill_band_requirement_at with no archived reviews or old skill tree level" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    assert_nil(user.met_associates_skill_band_requirement_at)
  end

  test "#met_associates_skill_band_requirement_at with old skill level exceeding required points" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_4
    })

    start_date = Date.new(2023, 1, 1)

    FullTimePeriod.create!({
      admin_user: user,
      started_at: start_date,
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    assert_in_delta(
      start_date,
      user.met_associates_skill_band_requirement_at,
      1.second
    )
  end

  test "#met_associates_skill_band_requirement_at with old skill level not exceeding required points" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :junior_1
    })

    start_date = Date.new(2023, 1, 1)

    FullTimePeriod.create!({
      admin_user: user,
      started_at: start_date,
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    assert_nil(user.met_associates_skill_band_requirement_at)
  end

  test "#skill_tree_level_without_salary when the user has an archived review" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    target_date = 5.days.ago

    user.reviews.create!({
      archived_at: target_date,
      finalization: Finalization.new({
        workspace: Workspace.new({
          status: "complete"
        })
      })
    })

    Review.any_instance.expects(:total_points).returns(400)

    assert_equal("ML3", user.skill_tree_level_without_salary)
  end

  test "#skill tree level_without_salary when the user does not have archived reviews but has an old skill tree level" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_3
    })

    assert_equal("S3", user.skill_tree_level_without_salary)
  end

  test "#skill_tree_level_without_salary when the user does not have an archived review or old skill tree level" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    assert_equal("No Reviews Yet", user.skill_tree_level_without_salary)
  end

  test "#skill_tree_level when the user has an archived review" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    target_date = 5.days.ago

    user.reviews.create!({
      archived_at: target_date,
      finalization: Finalization.new({
        workspace: Workspace.new({
          status: "complete"
        })
      })
    })

    Review.any_instance.expects(:total_points).returns(400).twice

    assert_equal("ML3 ($80,850)", user.skill_tree_level)
  end

  test "#skill_tree_level when the user does not have archived reviews but has an old skill tree level" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_3
    })

    assert_equal("S3 ($129,543.75)", user.skill_tree_level)
  end

  test "#skill_tree_level when the user does not have archived reviews or an old skill tree level" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    assert_equal("No Reviews Yet", user.skill_tree_level)
  end

  test "#skill_tree_level_on_date when the user has an archived review prior to the date" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    target_date = 5.days.ago

    user.reviews.create!({
      archived_at: target_date,
      finalization: Finalization.new({
        workspace: Workspace.new({
          status: "complete"
        })
      })
    })

    Review.any_instance.expects(:total_points).returns(400)

    assert_equal({
      name: "ML3",
      min_points: 375,
      salary: 80850
    }, user.skill_tree_level_on_date(2.days.ago))
  end

  test "#skill_tree_level_on_date when the user has an archived review but it falls after the date" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    target_date = 5.days.ago

    user.reviews.create!({
      archived_at: target_date,
      finalization: Finalization.new({
        workspace: Workspace.new({
          status: "complete"
        })
      })
    })

    assert_equal({
      name: "S1",
      min_points: 595,
      salary: 107231.25,
    }, user.skill_tree_level_on_date(7.days.ago))
  end

  test "#skill_tree_level_on_date when the user does not have an archived review but has an old skill tree level" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_3
    })

    assert_equal({
      name: "S3",
      min_points: 690,
      salary: 129543.75
    }, user.skill_tree_level_on_date(7.days.ago))
  end

  test "#skill_tree_level_on_date when the user does not have an archived review or old skill tree level" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    assert_equal({
      name: "S1",
      min_points: 595,
      salary: 107231.25
    }, user.skill_tree_level_on_date(7.days.ago))
  end

  test "#default_skill_level returns the expected value" do
    assert_equal({
      name: "S1",
      min_points: 595,
      salary: 107231.25
    }, AdminUser.default_skill_level)
  end

  test "It creates the user's initial salary window on create" do
    admin_user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    actual_windows = admin_user.admin_user_salary_windows.reload.map do |salary_window|
      salary_window.attributes.symbolize_keys.slice(:admin_user_id, :salary, :start_date, :end_date)
    end

    assert_equal([
      {
        admin_user_id: admin_user.id,
        salary: BigDecimal("107231.25"),
        start_date: Date.today,
        end_date: nil
      }
    ], actual_windows)
  end

  test "#cost_of_employment_on_date returns expected cost based on salary windows" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    user.admin_user_salary_windows.create!({
      salary: 123,
      start_date: Date.new(2022, 1, 1),
      end_date: Date.new(2023, 1, 1)
    })

    user.admin_user_salary_windows.create!({
      salary: 456,
      start_date: Date.new(2023, 1, 2),
      end_date: Date.new(2024, 1, 1)
    })

    user.admin_user_salary_windows.create!({
      salary: 789,
      start_date: Date.new(2024, 1, 2),
      end_date: nil
    })

    actual_cost = user.cost_of_employment_on_date(Date.new(2023, 6, 1))
    business_days = Stacks::Utils.business_days_between(
      Date.new(2023, 1, 1),
      Date.new(2023, 12, 31)
    )
    tax_benefits_factor = 1.1
    expected_cost = 456 * tax_benefits_factor / business_days

    assert_in_delta(expected_cost, actual_cost, 0.00001)
  end

  test "#cost_of_employment_on_date uses open-ended salary window when necessary" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    user.admin_user_salary_windows.delete_all

    user.admin_user_salary_windows.create!({
      salary: 123,
      start_date: Date.new(2022, 1, 1),
      end_date: Date.new(2023, 1, 1)
    })

    user.admin_user_salary_windows.create!({
      salary: 456,
      start_date: Date.new(2023, 1, 2),
      end_date: Date.new(2024, 1, 1)
    })

    user.admin_user_salary_windows.create!({
      salary: 789,
      start_date: Date.new(2024, 1, 2),
      end_date: nil
    })

    actual_cost = user.cost_of_employment_on_date(Date.new(2024, 6, 1))
    business_days = Stacks::Utils.business_days_between(
      Date.new(2024, 1, 1),
      Date.new(2024, 12, 31)
    )
    tax_benefits_factor = 1.1
    expected_cost = 789 * tax_benefits_factor / business_days

    assert_in_delta(expected_cost, actual_cost, 0.00001)
  end

  test "#cost_of_employment_on_date uses skill tree fallback if no matching salary window present" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_2
    })

    user.admin_user_salary_windows.create!({
      salary: 123,
      start_date: Date.new(2022, 1, 1),
      end_date: Date.new(2023, 1, 1)
    })

    user.admin_user_salary_windows.create!({
      salary: 456,
      start_date: Date.new(2023, 1, 2),
      end_date: Date.new(2024, 1, 1)
    })

    # Note: no salary window defined for 2024.

    actual_cost = user.cost_of_employment_on_date(Date.new(2024, 6, 1))
    business_days = Stacks::Utils.business_days_between(
      Date.new(2024, 1, 1),
      Date.new(2024, 12, 31)
    )
    tax_benefits_factor = 1.1
    expected_salary = 118125
    expected_cost = expected_salary * tax_benefits_factor / business_days

    assert_in_delta(expected_cost, actual_cost, 0.00001)
  end

  test "#cost_of_employment_on_date correctly tallies effective business days for four-day workers" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_2
    })

    date = Date.new(2022, 1, 1)

    user.full_time_periods.create!({
      started_at: Date.new(2021, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FOUR_DAY,
      expected_utilization: 0.8
    })

    actual_cost = user.cost_of_employment_on_date(date)

    business_days = Stacks::Utils.business_days_between(
      date.beginning_of_year,
      date.end_of_year
    )

    tax_benefits_factor = 1.1
    expected_salary = 105000
    expected_cost = expected_salary * tax_benefits_factor / (business_days * 0.8)

    assert_in_delta(expected_cost, actual_cost, 0.00001)
  end

  test "#full_time_period_at returns current full time period if date is in the future" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    user.full_time_periods.create!({
      started_at: Date.new(2021, 1, 1),
      ended_at: Date.new(2021, 12, 31),
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    user.full_time_periods.create!({
      started_at: Date.new(2022, 1, 1),
      ended_at: Date.new(2022, 12, 31),
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    expected_period = user.full_time_periods.create!({
      started_at: Date.new(2023, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    period = user.full_time_period_at(Date.today + 5.days)
    assert_equal(period, expected_period)
  end

  test "#full_time_period_at returns correct period for date in the past" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    user.full_time_periods.create!({
      started_at: Date.new(2021, 1, 1),
      ended_at: Date.new(2021, 12, 31),
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    expected_period = user.full_time_periods.create!({
      started_at: Date.new(2022, 1, 1),
      ended_at: Date.new(2022, 12, 31),
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    user.full_time_periods.create!({
      started_at: Date.new(2023, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    period = user.full_time_period_at(Date.new(2022, 6, 1))
    assert_equal(period, expected_period)
  end

  test "#full_time_period_at returns nil if no period is found" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    user.full_time_periods.delete_all
    period = user.full_time_period_at(Date.new(2022, 6, 1))

    assert_nil(period)
  end

  test "#approximate_cost_per_hour_before_studio_expenses returns the expected value" do
    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_2
    })

    actual_cost = user.approximate_cost_per_hour_before_studio_expenses
    expected_cost = 62.2306

    if Date.today.leap?
      assert_in_delta(62.2306, actual_cost, 0.0001)
    else
      assert_in_delta(62.4699, actual_cost, 0.0001)
    end
  end
end

