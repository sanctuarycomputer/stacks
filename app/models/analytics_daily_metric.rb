class AnalyticsDailyMetric < ApplicationRecord
  BREAKDOWNS = %w[total traffic landing_page].freeze
  OTHER = "(other)".freeze

  belongs_to :analytics_property

  validates :breakdown, inclusion: { in: BREAKDOWNS }

  before_validation { self.dims_key = self.class.dims_key(source, medium, campaign, landing_page) }

  def self.dims_key(source, medium, campaign, landing_page)
    Digest::SHA1.hexdigest([source, medium, campaign, landing_page].map(&:to_s).join("\u0000"))
  end
end
