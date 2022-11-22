class Stacks::Period
  attr_accessor :label
  attr_accessor :starts_at
  attr_accessor :ends_at

  def initialize(label, starts_at, ends_at)
    @label = label
    @starts_at = starts_at
    @ends_at = ends_at
  end

  def report
    @_report ||= QboProfitAndLossReport.find_or_fetch_for_range(
      starts_at,
      ends_at
    )
  end

  def has_utilization_data?
    @starts_at >= Stacks::System.singleton_class::UTILIZATION_START_AT
  end

  def has_new_biz_version_history?
    @starts_at >= Stacks::System.singleton_class::NEW_BIZ_VERSION_HISTORY_START_AT
  end

  def include?(date)
    date >= @starts_at && date <= @ends_at
  end

  def self.for_gradation(gradation)
    periods = []
    time = Date.new(2020, 1, 1)
    case gradation
    when nil
    when :month
      while time < Date.today.last_month.end_of_month
        periods << Stacks::Period.new(
          time.strftime("%B, %Y"),
          time.beginning_of_month,
          time.end_of_month
        )
        time = time.advance(months: 1)
      end
    when :quarter
      while time < Date.today.last_quarter.end_of_quarter
        periods << Stacks::Period.new(
          "Q#{(time.beginning_of_quarter.month / 3) + 1}, #{time.beginning_of_quarter.year}",
          time.beginning_of_quarter,
          time.end_of_quarter
        )
        time = time.advance(months: 3)
      end
    when :year
      while time < Date.today.last_year.end_of_year
        periods << Stacks::Period.new(
          "#{time.beginning_of_quarter.year}",
          time.beginning_of_year,
          time.end_of_year
        )
        time = time.advance(years: 1)
      end
    end
    periods
  end
end
