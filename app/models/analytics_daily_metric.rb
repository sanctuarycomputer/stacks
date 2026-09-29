class AnalyticsDailyMetric < ApplicationRecord
  BREAKDOWNS = %w[total traffic landing_page].freeze
  OTHER = "(other)".freeze

  belongs_to :analytics_property

  validates :breakdown, inclusion: { in: BREAKDOWNS }
end
