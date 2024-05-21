require 'test_helper'

class FullTimePeriodTest < ActiveSupport::TestCase
  test "#include? returns true for dates that are within the specified period" do
    period = FullTimePeriod.new({
      started_at: Date.today - 1.year,
      ended_at: Date.today - 6.months
    })

    assert period.include?(Date.today - 9.months)
  end

  test "#include? returns false for dates that are before the specified period" do
    period = FullTimePeriod.new({
      started_at: Date.today - 1.year,
      ended_at: Date.today - 6.months
    })

    refute period.include?(Date.today - 2.years)
  end

  test "#include? returns false for dates that are after the specified period" do
    period = FullTimePeriod.new({
      started_at: Date.today - 1.year,
      ended_at: Date.today - 6.months
    })

    refute period.include?(Date.today)
  end

  test "#include? returns true for dates that fall after the start date, and the period does not have an end date" do
    period = FullTimePeriod.new({
      started_at: Date.today - 1.year
    })

    assert period.include?(Date.today)
  end
end
