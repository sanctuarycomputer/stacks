require 'test_helper'

class Stacks::TeamTest < ActiveSupport::TestCase
  test "It can calculate the total units on a date, in a non-diluted scenario" do
    FullTimePeriod.create!({
      started_at: Date.today - 1.day,
      admin_user: AdminUser.create!({
        email: "fulltime1@sanctuary.computer",
        password: "password",
      }),
      contributor_type: FullTimePeriod.contributor_types["five_day"]
    })

    FullTimePeriod.create!({
      started_at: Date.today - 1.day,
      admin_user: AdminUser.create!({
        email: "fulltime2@sanctuary.computer",
        password: "password",
      }),
      contributor_type: FullTimePeriod.contributor_types["four_day"]
    })

    FullTimePeriod.create!({
      started_at: Date.today - 10.days, # Not counted as this is a variable_hours worker
      admin_user: AdminUser.create!({
        email: "not_fulltime@sanctuary.computer",
        password: "password",
      }),
      contributor_type: FullTimePeriod.contributor_types["variable_hours"]
    })

    assert Stacks::Team.admin_users_sorted_by_tenure_in_days.length == 2
    assert Stacks::Team.mean_tenure_in_days == 1
  end
end
