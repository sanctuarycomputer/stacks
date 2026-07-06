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

  test "#four_day? returns true for four-day contributor type" do
    period = FullTimePeriod.new({
      contributor_type: Enum::ContributorType::FOUR_DAY
    })

    assert period.four_day?
  end

  test "#four_day? returns false for other contributor types" do
    period = FullTimePeriod.new({
      contributor_type: Enum::ContributorType::FIVE_DAY
    })

    refute period.four_day?
  end

  test "#five_day? returns true for five-day contributor type" do
    period = FullTimePeriod.new({
      contributor_type: Enum::ContributorType::FIVE_DAY
    })

    assert period.five_day?
  end

  test "#five_day? returns false for other contributor types" do
    period = FullTimePeriod.new({
      contributor_type: Enum::ContributorType::FOUR_DAY
    })

    refute period.five_day?
  end

  test "#psu_earn_rate returns expected rate for 4-day workers" do
    period = FullTimePeriod.new({
      contributor_type: Enum::ContributorType::FOUR_DAY
    })

    assert_equal(0.8, period.psu_earn_rate)
  end

  test "#psu_earn_rate returns expected rate for 5-day workers" do
    period = FullTimePeriod.new({
      contributor_type: Enum::ContributorType::FIVE_DAY
    })

    assert_equal(1, period.psu_earn_rate)
  end

  test "#psu_earn_rate returns expected rate for variable hours workers" do
    period = FullTimePeriod.new({
      contributor_type: Enum::ContributorType::VARIABLE_HOURS
    })

    assert_equal(0, period.psu_earn_rate)
  end
end
