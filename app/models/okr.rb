FauxOKR = Struct.new(:name)

class Okr < ApplicationRecord
  has_many :okr_periods, dependent: :destroy
  accepts_nested_attributes_for :okr_periods, allow_destroy: true

  validates_uniqueness_of :name
  validates_presence_of :name
  validates_presence_of :operator
  validates_presence_of :datapoint

  enum operator: {
    less_than: 0,
    greater_than: 1,
    compounding_annual_rate_less_than: 2,
    compounding_annual_rate_greater_than: 3,
  }

  enum datapoint: {
    sellable_hours_sold: 0,
    average_hourly_rate: 1,
    cost_per_sellable_hour: 2,
    actual_cost_per_hour_sold: 3,
    revenue: 4,
    payroll: 5,
    benefits: 6,
    total_expenses: 7,
    subcontractors: 8,
    sellable_hours: 9,
    non_sellable_hours: 10,
    billable_hours: 11,
    time_off: 12,
    profit_margin: 13,
    # key_meeting_attendance: 14,
    total_social_growth: 15,
    free_hours: 16,
    total_projects: 17,
    successful_projects: 18,
    successful_proposals: 19,
    revenue_growth: 20,
    lead_growth: 21,
    workplace_satisfaction: 22,
  }

  def self.make_annual_growth_progress_data(target, tolerance, last_year_value, current_value, base_unit_type)
    growth_progress = {
      eoy: {
        low: last_year_value * (1 + (target - tolerance)/100.0),
        mid: last_year_value * (1 + (target)/100.0),
        high: last_year_value * (1 + (target + tolerance)/100.0),
      },
      today: {
        low: 0,
        mid: 0,
        high: 0,
        actual: current_value
      },
      abs: 0,
      total_days_this_year: Date.today.end_of_year.yday.to_f,
      elapsed_days_this_year: Date.today.yday.to_f,
      unit: base_unit_type
    }

    growth_progress[:today][:low] = ((growth_progress[:eoy][:low] / growth_progress[:total_days_this_year]) * growth_progress[:elapsed_days_this_year])
    growth_progress[:today][:mid] = ((growth_progress[:eoy][:mid] / growth_progress[:total_days_this_year]) * growth_progress[:elapsed_days_this_year])
    growth_progress[:today][:high] = ((growth_progress[:eoy][:high] / growth_progress[:total_days_this_year]) * growth_progress[:elapsed_days_this_year])
    growth_progress[:abs] = [growth_progress[:eoy][:high], growth_progress[:today][:actual]].max
    growth_progress[:health] = if growth_progress[:today][:actual] >= growth_progress[:today][:high]
      :exceptional
    elsif growth_progress[:today][:actual] >= growth_progress[:today][:mid]
      :healthy
    elsif growth_progress[:today][:actual] >= growth_progress[:today][:low]
      :at_risk
    else
      :failing
    end

    growth_progress
  end
end
