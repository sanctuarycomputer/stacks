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

  def health_for_value(value)
    return { health: nil, surplus: 0, tolerance: tolerance } if value == nil
    surplus = value - target
    extreme = surplus.abs > tolerance

    tag =
      if okr.operator == "greater_than"
        surplus > 0 ?
        extreme ? :exceptional : :healthy :
        extreme ? :failing : :at_risk
      elsif okr.operator == "less_than"
        surplus < 0 ?
        extreme ? :exceptional : :healthy :
        extreme ? :failing : :at_risk
      else
        raise "unknown_operator"
      end
    {
      health: tag,
      surplus: surplus,
      target: target,
      tolerance: tolerance
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
