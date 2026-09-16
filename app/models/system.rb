class System < ApplicationRecord
  has_many :notifications, as: :recipient
  include Storext.model

  before_create :confirm_singularity

  store_attributes :settings do
    default_hourly_rate Float, default: 175
    tentative_assignment_label String, default: "Tentative"
    expected_skill_tree_cadence_days Integer, default: 365
    ghost_synced_sources Array, default: []
    ghost_newsletter_prefix_map Hash, default: {}
    ghost_newsletter_grants_enabled Boolean, default: false
    ghost_sweep_write_budget Integer, default: 2500
    ghost_last_sync_summary Hash, default: {}
  end

  def display_name
    "Stacks"
  end

  # Storext/Virtus stores "" and "abc" verbatim for an Integer attribute, so the
  # raw reader can hand back a String and `budget > 0` raises ArgumentError. In
  # stacks.rake that exception is swallowed into a log line, which would silently
  # stop the daily Ghost sync. Always read the budget through here.
  def ghost_sweep_write_budget_clamped
    [ghost_sweep_write_budget.to_i, 1].max
  end

  # A blank map value would otherwise be a truthy "newsletter id".
  def ghost_newsletter_prefix_map_clean
    ghost_newsletter_prefix_map.to_h
      .transform_keys { |k| k.to_s.downcase }
      .reject { |_, v| v.to_s.blank? }
  end

  private

  def self.instance
    @@instance ||= (first || System.create!(settings: {}))
  end

  def confirm_singularity
    raise Exception.new("There can be only one.") if System.count > 0
  end
end
