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
      contributor_type: :five_day,
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
      contributor_type: :five_day,
      expected_utilization: 0.8
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2021, 6, 5),
      ended_at: nil,
      contributor_type: :five_day,
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
      contributor_type: :five_day,
      expected_utilization: 0.8
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2021, 1, 1),
      ended_at: nil,
      contributor_type: :four_day,
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
      contributor_type: :five_day,
      expected_utilization: 0.8
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 12, 16),
      ended_at: nil,
      contributor_type: :four_day,
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
      contributor_type: :five_day,
      expected_utilization: 0.8
    })
    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 12, 16),
      ended_at: nil,
      contributor_type: :five_day,
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
      contributor_type: :five_day,
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
      contributor_type: :five_day,
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
end
