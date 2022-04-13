class System < ApplicationRecord
  include Storext.model

  before_create :confirm_singularity

  store_attributes :settings do
    default_hourly_rate Float, default: 175
    tentative_assignment_label String, default: "Tentative"
  end

  def display_name
    "Stacks"
  end

  private

  def self.instance
    first || System.create!(settings: {})
  end

  def confirm_singularity
    raise Exception.new("There can be only one.") if System.count > 0
  end
end
