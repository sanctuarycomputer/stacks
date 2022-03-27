class Stacks::Period
  attr_accessor :label
  attr_accessor :starts_at
  attr_accessor :ends_at
  attr_accessor :report

  def initialize(label, starts_at, ends_at)
    @label = label
    @starts_at = starts_at
    @ends_at = ends_at
    @report = QboProfitAndLossReport.find_or_fetch_for_range(
      starts_at,
      ends_at
    )
  end

  def has_utilization_data?
    @starts_at >= Stacks::System.singleton_class::UTILIZATION_START_AT
  end
end
