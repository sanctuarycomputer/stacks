class OkrPeriodStudio < ApplicationRecord
  belongs_to :studio
  belongs_to :okr_period

  def applies_to?(period)
    okr_period.period_starts_at <= period.starts_at &&
    okr_period.period_ends_at >= period.ends_at
  end
end
