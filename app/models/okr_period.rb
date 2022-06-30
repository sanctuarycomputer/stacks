class OkrPeriod < ApplicationRecord
  validate :does_not_overlap
  validate :ends_at_before_starts_at?
  validates_presence_of :target
  validates_presence_of :tolerance

  belongs_to :okr
  has_many :okr_period_studios, dependent: :delete_all
  accepts_nested_attributes_for :okr_period_studios, allow_destroy: true

  def health_for_value(value)
    return { health: nil, surplus: 0 } if value == nil
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
    { health: tag, surplus: surplus }
  end

  def period_starts_at
    starts_at || Date.new(2015, 1, 1)
  end

  def period_ends_at
    ends_at || Date.new(3015, 1, 1)
  end

  def does_not_overlap
    overlap =
      okr.okr_periods
        .reject{|p| p.id.nil?}
        .reject{|p| p == self}
        .find{|p| self.overlaps?(p)}
    if overlap.present?
      errors.add(:starts_at, "Must not overlap with another period")
    end
  end

  def overlaps?(other)
    period_starts_at <= other.period_ends_at &&
    other.period_starts_at <= period_ends_at
  end

  def ends_at_before_starts_at?
    if starts_at.present? && ends_at.present?
      unless ends_at > starts_at
        errors.add(:starts_at, "Must be before ends_at")
      end
    end
  end
end
