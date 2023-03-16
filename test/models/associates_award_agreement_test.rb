require 'test_helper'

class AssociatesAwardAgreementTest < ActiveSupport::TestCase
  test "It can calculate the total units on a date, in a non-diluted scenario" do
    admin_user = AdminUser.create!({
      email: "jacob@xxix.co",
      password: "passw0rd",
    })
    award_agreement = AssociatesAwardAgreement.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 1, 1),
      initial_unit_grant: 69_476,
      vesting_unit_increments:  69_444,
      vesting_periods: 71,
      vesting_period_type: :month,
    })

    assert award_agreement.vested_units_on(Date.new(2019, 12, 31)) == 0
    assert award_agreement.vested_units_on(Date.new(2020, 1, 1)) == 69_476
    assert award_agreement.vested_units_on(Date.new(2020, 2, 1)) == 69_476 + 69_444

    assert award_agreement.vested_units_on(Date.new(2025, 11, 30)) == 69_476 + (69_444 * 70)
    assert award_agreement.vested_units_on(Date.new(2025, 12, 1)) == 69_476 + (69_444 * 71)
    assert award_agreement.vested_units_on(Date.new(2026, 1, 1)) == 69_476 + (69_444 * 71)
  end

  test "It can calculate the % of the pool on a date, in a non-diluted scenario" do
    admin_user = AdminUser.create!({
      email: "jacob@xxix.co",
      password: "passw0rd",
    })
    award_agreement = AssociatesAwardAgreement.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 1, 1),
      initial_unit_grant: 69_476,
      vesting_unit_increments:  69_444,
      vesting_periods: 71,
      vesting_period_type: :month,
    })

    assert award_agreement.percentage_of_pool_on(Date.new(2019, 12, 31)) == 0
    assert award_agreement.percentage_of_pool_on(Date.new(2020, 1, 1)) == 0.00138952
    assert award_agreement.percentage_of_pool_on(Date.new(2020, 11, 30)) != 0.1
    assert award_agreement.percentage_of_pool_on(Date.new(2025, 12, 1)) == 0.1
  end

  test "It can calculate the % of the pool owner on a date, in a non-diluted scenario" do
    admin_user = AdminUser.create!({
      email: "jacob@xxix.co",
      password: "passw0rd",
    })
    award_agreement = AssociatesAwardAgreement.create!({
      admin_user: admin_user,
      started_at: Date.new(2020, 1, 1),
      initial_unit_grant: 69_476,
      vesting_unit_increments:  69_444,
      vesting_periods: 71,
      vesting_period_type: :month,
    })

    assert AssociatesAwardAgreement.pool_owner_percentage_of_pool_on(Date.new(2019, 12, 31)) == 1
    assert AssociatesAwardAgreement.pool_owner_percentage_of_pool_on(Date.new(2020, 1, 1)) == (1 - award_agreement.percentage_of_pool_on(Date.new(2020, 1, 1)))
    assert AssociatesAwardAgreement.pool_owner_percentage_of_pool_on(Date.new(2025, 12, 1)) == 0.9
  end

  # DILUTED SCENARIOS

  test "It can calculate the total units on a date, in a diluted scenario" do
    9.times do |i|
      admin_user = AdminUser.create!({
        email: "user-#{i}@xxix.co",
        password: "passw0rd",
      })
      award_agreement = AssociatesAwardAgreement.create!({
        admin_user: admin_user,
        started_at: Date.new(2020, 1, 1),
        initial_unit_grant: 69_476,
        vesting_unit_increments:  69_444,
        vesting_periods: 71,
        vesting_period_type: :month,
      })
    end

    assert AssociatesAwardAgreement.pool_owner_percentage_of_pool_on(Date.new(2019, 12, 31)) == 1
    assert AssociatesAwardAgreement.total_award_units_issued_on(Date.new(2019, 12, 31)) == 0
    assert AssociatesAwardAgreement.total_award_units_issued_on(Date.new(2020, 1, 1)) == 69_476 * 9

    # At this point, all 9 users have vested 5_000_000 units, which is a dilution scenario
    assert AssociatesAwardAgreement.total_award_units_issued_on(Date.new(2025, 12, 1)) == (69_476 + (69_444 * 71)) * 9
    assert AssociatesAwardAgreement.total_award_units_issued_on(Date.new(2025, 12, 1)) > AssociatesAwardAgreement::INITIAL_AWARDABLE_POOL

    # The pool owner is now diluted to 18.18% (recurring)
    assert AssociatesAwardAgreement.pool_owner_percentage_of_pool_on(Date.new(2025, 12, 1)) == 0.18181818181818166

    # Ensure the diluted ppl + pool owner === 1
    assert (
      AssociatesAwardAgreement.pool_owner_percentage_of_pool_on(Date.new(2025, 12, 1)) + 
      AssociatesAwardAgreement.all.map{|a| a.percentage_of_pool_on(Date.new(2025, 12, 1))}.reduce(:+)
    ) == 1
  end
end
