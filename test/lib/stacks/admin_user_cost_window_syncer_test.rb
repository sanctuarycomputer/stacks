require 'test_helper'

class Stacks::AdminUserCostWindowSyncerTest < ActiveSupport::TestCase
  test "It builds the expected salary window using the default skill level for a user without any archived reviews" do
    user = AdminUser.create!({
      created_at: Date.today - 5.days,
      email: "josh@sanctuary.computer",
      password: "password"
    })

    syncer = Stacks::AdminUserSalaryWindowSyncer.new(user)
    syncer.sync!

    assert_salary_windows(user, [
      {
        admin_user_id: user.id,
        salary: BigDecimal("107231.25"),
        start_date: Date.today - 5.days,
        end_date: nil
      }
    ])
  end

  test "It builds the expected salary window using the old skill level for a user without any archived reviews" do
    user = AdminUser.create!({
      created_at: Date.today - 5.days,
      old_skill_tree_level: :experienced_mid_level_1,
      email: "josh@sanctuary.computer",
      password: "password"
    })

    syncer = Stacks::AdminUserSalaryWindowSyncer.new(user)
    syncer.sync!

    assert_salary_windows(user, [
      {
        admin_user_id: user.id,
        salary: BigDecimal(84000),
        start_date: Date.today - 5.days,
        end_date: nil
      }
    ])
  end

  test "It builds the expected salary windows for a user with an archived review" do
    user = AdminUser.create!({
      created_at: Date.today - 1.year,
      old_skill_tree_level: :experienced_mid_level_1,
      email: "josh@sanctuary.computer",
      password: "password"
    })

    create_review!(user, Date.today - 6.months)

    Review.any_instance.stubs(:total_points).returns(630)

    syncer = Stacks::AdminUserSalaryWindowSyncer.new(user)
    syncer.sync!

    assert_salary_windows(user, [
      {
        admin_user_id: user.id,
        salary: BigDecimal(84000),
        start_date: Date.today - 1.year,
        end_date: Date.today - 6.months - 1.day
      },
      {
        admin_user_id: user.id,
        salary: BigDecimal("107231.25"),
        start_date: Date.today - 6.months,
        end_date: nil
      }
    ])
  end

  test "It does not build multiple windows for adjacent matching time periods" do
    user = AdminUser.create!({
      created_at: Date.today - 1.year,
      old_skill_tree_level: :experienced_mid_level_1,
      email: "josh@sanctuary.computer",
      password: "password"
    })

    create_review!(user, Date.today - 6.months)
    # No salary window will be created for this duplicate review period:
    create_review!(user, Date.today - 3.months)

    Review.any_instance.stubs(:total_points).returns(630)

    syncer = Stacks::AdminUserSalaryWindowSyncer.new(user)
    syncer.sync!

    assert_salary_windows(user, [
      {
        admin_user_id: user.id,
        salary: BigDecimal(84000),
        start_date: Date.today - 1.year,
        end_date: Date.today - 6.months - 1.day
      },
      {
        admin_user_id: user.id,
        salary: BigDecimal("107231.25"),
        start_date: Date.today - 6.months,
        end_date: nil
      }
    ])
  end

  test "It creates distinct windows for the user if the contributor type changes for adjacent full-time periods" do
    user = AdminUser.create!({
      created_at: Date.today - 1.year,
      old_skill_tree_level: :experienced_mid_level_1,
      email: "josh@sanctuary.computer",
      password: "password"
    })

    user.full_time_periods.create!({
      started_at: Date.today - 1.year,
      ended_at: Date.today - 6.months - 1.day,
      contributor_type: :five_day
    })

    user.full_time_periods.create!({
      started_at: Date.today - 6.months,
      contributor_type: :four_day
    })

    syncer = Stacks::AdminUserSalaryWindowSyncer.new(user)
    syncer.sync!

    assert_salary_windows(user, [
      {
        admin_user_id: user.id,
        salary: BigDecimal(84000),
        start_date: Date.today - 1.year,
        end_date: Date.today - 6.months - 1.day
      },
      {
        admin_user_id: user.id,
        salary: BigDecimal(67200),
        start_date: Date.today - 6.months,
        end_date: nil
      }
    ])
  end

  test "It creates distinct windows for the user based on the time ranges of company-wide salary changes" do
    user = AdminUser.create!({
      created_at: Date.new(2020, 1, 1),
      old_skill_tree_level: :senior_4,
      email: "josh@sanctuary.computer",
      password: "password"
    })

    syncer = Stacks::AdminUserSalaryWindowSyncer.new(user)
    syncer.sync!

    assert_salary_windows(user, [
      {
        admin_user_id: user.id,
        salary: BigDecimal(110000),
        start_date: Date.new(2020, 1, 1),
        end_date: Date.new(2021, 12, 7)
      },
      {
        admin_user_id: user.id,
        salary: BigDecimal(115500),
        start_date: Date.new(2021, 12, 8),
        end_date: Date.new(2022, 7, 4)
      },
      {
        admin_user_id: user.id,
        salary: BigDecimal("141487.5"),
        start_date: Date.new(2022, 7, 5),
        end_date: nil
      }
    ])
  end

  test "It does not create distinct windows for the user across company-wide salary changes if the user's salary did not explicitly change as a result" do
    user = AdminUser.create!({
      created_at: Date.new(2022, 1, 1),
      old_skill_tree_level: :junior_1,
      email: "josh@sanctuary.computer",
      password: "password"
    })

    syncer = Stacks::AdminUserSalaryWindowSyncer.new(user)
    syncer.sync!

    assert_salary_windows(user, [
      {
        admin_user_id: user.id,
        salary: BigDecimal(63000),
        start_date: Date.new(2022, 1, 1),
        end_date: nil
      }
    ])
  end

  private

  def assert_salary_windows(admin_user, expected_windows)
    actual_windows = admin_user.admin_user_salary_windows.reload.map do |salary_window|
      salary_window.attributes.symbolize_keys.slice(:admin_user_id, :salary, :start_date, :end_date)
    end

    assert_equal(expected_windows, actual_windows)
  end

  def create_review!(admin_user, archived_at)
    review = admin_user.reviews.create!

    review.finalization.workspace.update!({
      status: "complete"
    })

    review.update!({
      archived_at: archived_at
    })
  end
end
