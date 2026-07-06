require 'test_helper'

class Stacks::TeamTest < ActiveSupport::TestCase
  test "It can calculate retention" do
    FullTimePeriod.create!({
      started_at: Date.today - 1.day,
      admin_user: AdminUser.create!({
        email: "fulltime1@sanctuary.computer",
        password: "password",
      }),
      contributor_type: Enum::ContributorType::FIVE_DAY
    })

    FullTimePeriod.create!({
      started_at: Date.today - 1.day,
      admin_user: AdminUser.create!({
        email: "fulltime2@sanctuary.computer",
        password: "password",
      }),
      contributor_type: Enum::ContributorType::FOUR_DAY
    })

    FullTimePeriod.create!({
      started_at: Date.today - 10.days, # Not counted as this is a variable_hours worker
      admin_user: AdminUser.create!({
        email: "not_fulltime@sanctuary.computer",
        password: "password",
      }),
      contributor_type: Enum::ContributorType::VARIABLE_HOURS
    })

    assert Stacks::Team.admin_users_sorted_by_tenure_in_days.length == 2
    assert Stacks::Team.mean_tenure_in_days == 1
  end

  test "It does not include considered_temporary workers when calculating retention" do
    FullTimePeriod.create!({
      started_at: Date.today - 1.day,
      admin_user: AdminUser.create!({
        email: "fulltime1@sanctuary.computer",
        password: "password",
      }),
      contributor_type: Enum::ContributorType::FIVE_DAY
    })

    FullTimePeriod.create!({
      started_at: Date.today - 1.day,
      admin_user: AdminUser.create!({
        email: "fulltime2@sanctuary.computer",
        password: "password",
      }),
      contributor_type: Enum::ContributorType::FOUR_DAY
    })

    FullTimePeriod.create!({
      started_at: Date.today - 100.days, # Not counted as this is a considered_temporary worker
      admin_user: AdminUser.create!({
        email: "not_fulltime@sanctuary.computer",
        password: "password",
      }),
      contributor_type: Enum::ContributorType::FOUR_DAY,
      considered_temporary: true
    })

    assert Stacks::Team.admin_users_sorted_by_tenure_in_days.length == 3
    assert Stacks::Team.mean_tenure_in_days == 1
  end
end
