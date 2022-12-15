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
      ended_at: Date.new(2020, 12, 31),
      contributor_type: :five_day,
      expected_utilization: 0.8
    })
    admin_user.full_time_periods.reload

    # User had not started their employment yet
    assert admin_user.psu_earned_by(Date.new(2019, 1, 1)) == 0

    # User has completed 6 full months
    assert admin_user.psu_earned_by(Date.new(2020, 5, 31)) == 4
    assert admin_user.psu_earned_by(Date.new(2020, 6, 1)) == 5

    # User ended their employment before their 12th PSU clicked over
    assert admin_user.psu_earned_by(Date.new(2021, 1, 1)) == 11
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
    assert admin_user.psu_earned_by(Date.new(2019, 1, 1)) == 0

    # User is not currently employed at this point
    assert admin_user.psu_earned_by(Date.new(2021, 1, 1)) == 11

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
end
