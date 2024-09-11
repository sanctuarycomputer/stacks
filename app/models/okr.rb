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
    successful_projects: 18
  }
end
