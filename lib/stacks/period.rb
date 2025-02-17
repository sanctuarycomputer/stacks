class Stacks::Period
  attr_accessor :label
  attr_accessor :starts_at
  attr_accessor :ends_at

  def initialize(label, starts_at, ends_at)
    @label = label
    @starts_at = starts_at
    @ends_at = ends_at
  end

  def report(qbo_account = nil)
    @_report ||= QboProfitAndLossReport.find_or_fetch_for_range(
      starts_at,
      ends_at,
      false,
      qbo_account
    )
  end

  def self.all
    @_all ||= [:year, :month, :quarter, :trailing_3_months, :trailing_4_months, :trailing_6_months, :trailing_12_months].map do |gradation|
      Stacks::Period.for_gradation(gradation)
    end.flatten
  end

  def total_days
    (ends_at - starts_at).to_i
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

  def self.for_gradation(gradation, start_at = Date.new(2020, 1, 1))
    periods = []
    case gradation
    when nil
    when :month
      time = start_at
      while time < Date.today.last_month.end_of_month
        periods << Stacks::Period.new(
          time.strftime("%B, %Y"),
          time.beginning_of_month,
          time.end_of_month
        )
        time = time.advance(months: 1)
      end
      return periods

    when :quarter
      time = start_at
      while time < Date.today.last_quarter.end_of_quarter
        periods << Stacks::Period.new(
          "Q#{(time.beginning_of_quarter.month / 3) + 1}, #{time.beginning_of_quarter.year}",
          time.beginning_of_quarter,
          time.end_of_quarter
        )
        time = time.advance(months: 3)
      end
      return periods

    when :year
      time = start_at
      while time < Date.today.last_year.end_of_year
        periods << Stacks::Period.new(
          "#{time.beginning_of_quarter.year}",
          time.beginning_of_year,
          time.end_of_year
        )
        time = time.advance(years: 1)
      end
      periods << Stacks::Period.new(
        "YTD",
        Date.today.beginning_of_year,
        Date.today.end_of_year
      )
      return periods

    when :trailing_3_months
      time = Date.today.last_month
      while time > start_at
        starts_at = (time - 2.months).beginning_of_month
        ends_at = time.end_of_month
        periods << Stacks::Period.new(
          "#{starts_at.strftime("%B, %Y")} - #{ends_at.strftime("%B, %Y")}",
          starts_at,
          ends_at
        )
        time = time - 3.months
      end
      return periods.reverse

    when :trailing_4_months
      time = Date.today.last_month
      while time > start_at
        starts_at = (time - 3.months).beginning_of_month
        ends_at = time.end_of_month
        periods << Stacks::Period.new(
          "#{starts_at.strftime("%B, %Y")} - #{ends_at.strftime("%B, %Y")}",
          starts_at,
          ends_at
        )
        time = time - 4.months
      end
      return periods.reverse

    when :trailing_6_months
      time = Date.today.last_month
      while time > start_at
        starts_at = (time - 5.months).beginning_of_month
        ends_at = time.end_of_month
        periods << Stacks::Period.new(
          "#{starts_at.strftime("%B, %Y")} - #{ends_at.strftime("%B, %Y")}",
          starts_at,
          ends_at
        )
        time = time - 6.months
      end
      return periods.reverse

    when :trailing_12_months
      time = Date.today.last_month
      while time > start_at
        starts_at = (time - 11.months).beginning_of_month
        ends_at = time.end_of_month
        periods << Stacks::Period.new(
          "#{starts_at.strftime("%B, %Y")} - #{ends_at.strftime("%B, %Y")}",
          starts_at,
          ends_at
        )
        time = time - 12.months
      end
      return periods.reverse

    end
  end
end
