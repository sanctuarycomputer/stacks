# One Google Analytics (GA4) property we sync: a site, by name. Edited in the admin
# (Site Analytics → Properties). Not linked to a studio: one company, many sites.
class AnalyticsProperty < ApplicationRecord
  has_many :analytics_daily_metrics, dependent: :delete_all

  before_validation { self.ga4_property_id = ga4_property_id.to_s.strip.delete_prefix("properties/") }

  validates :name, presence: true, uniqueness: true
  validates :ga4_property_id, presence: true, uniqueness: true, format: { with: /\A\d+\z/, message: "is the numeric GA4 property id (Admin → Property details), not a G- measurement id" }

  scope :active, -> { where(active: true) }

  # A site by name, URL fragment or property id (case-insensitive), for the MCP tool.
  def self.matching(query)
    q = query.to_s.strip.downcase
    return none if q.blank?

    exact = active.select { |p| [p.name.downcase, p.ga4_property_id, host(p.site_url)].include?(q) }
    return where(id: exact.map(&:id)) if exact.any?

    where(id: active.select { |p| p.name.downcase.include?(q) || p.site_url.to_s.downcase.include?(q) }.map(&:id))
  end

  def self.host(url)
    url.to_s.downcase.sub(%r{\Ahttps?://}, "").sub(/\Awww\./, "").split("/").first.to_s
  end
end
