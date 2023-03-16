class AssociatesAwardAgreement < ApplicationRecord
  belongs_to :admin_user

  POOL_OWNER_UNITS = 10_000_000.to_f
  INITIAL_AWARDABLE_POOL = 40_000_000.to_f

  enum vesting_period_type: {
    month: 0
  }

  def self.total_award_units_issued_on(date = Date.today)
    AssociatesAwardAgreement.all.map do |a|
      a.vested_units_on(date)
    end.reduce(:+) || 0
  end

  def self.pool_owner_percentage_of_pool_on(date = Date.today)
    1 - AssociatesAwardAgreement.all.map{|a| a.percentage_of_pool_on(date)}.reduce(:+)
  end

  def vested_units_on(date = Date.today)
    return 0 if date < started_at

    full_months = Stacks::Utils.full_months_between(date, started_at)
    if full_months < vesting_periods
      initial_unit_grant + (vesting_unit_increments * full_months)
    else
      initial_unit_grant + (vesting_unit_increments * vesting_periods)
    end
  end

  def percentage_of_pool_on(date = Date.today)
    vested_units = vested_units_on(date)
    return 0 if vested_units == 0

    total_issued = AssociatesAwardAgreement.total_award_units_issued_on(date)
    vested_units / ([total_issued, INITIAL_AWARDABLE_POOL].max + POOL_OWNER_UNITS)
  end
end
