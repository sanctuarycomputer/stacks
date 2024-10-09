class OkrPeriod < ApplicationRecord
  include ActsAsPeriod

  validates_presence_of :target
  validates_presence_of :tolerance

  belongs_to :okr
  has_many :okr_period_studios, dependent: :delete_all
  accepts_nested_attributes_for :okr_period_studios, allow_destroy: true

  def started_at
    starts_at
  end

  def ended_at
    ends_at
  end

  def self.target_growth_rate_for_period(annual_growth_rate, days_in_period)
    # Convert annual growth rate from percentage to decimal
    r = annual_growth_rate / 100.0

    # Calculate the daily growth rate using the formula
    daily_growth = (1 + r) ** (1.0 / 365) - 1

    # Calculate the growth rate for the specified number of days
    target_growth = (1 + daily_growth) ** days_in_period - 1

    # Convert the result back to percentage
    target_growth * 100
  end

  def health_for_value(value, total_days)
    working_target = target
    working_tolerance = tolerance

    if okr.operator.starts_with?("compounding_annual_rate")
      working_target = OkrPeriod.target_growth_rate_for_period(target, total_days)
      working_tolerance = OkrPeriod.target_growth_rate_for_period(tolerance, total_days)
    end

    return { health: nil, surplus: 0, tolerance: working_tolerance } if value == nil

    surplus = value - working_target
    extreme = surplus.abs > working_tolerance

    tag =
      case okr.operator
      when "less_than", "compounding_annual_rate_less_than"
        surplus < 0 ?
          extreme ? :exceptional : :healthy :
          extreme ? :failing : :at_risk
      when "greater_than", "compounding_annual_rate_greater_than"
        surplus > 0 ?
          extreme ? :exceptional : :healthy :
          extreme ? :failing : :at_risk
      else
        raise "unknown_operator"
      end

    {
      health: tag,
      surplus: surplus,
      target: working_target,
      tolerance: working_tolerance
    }
  end

  def period_starts_at
    starts_at || Date.new(2015, 1, 1)
  end

  def period_ends_at
    ends_at || Date.new(3015, 1, 1)
  end

  def sibling_periods
    okr.okr_periods
  end
end
