class ForecastProject < ApplicationRecord
  self.primary_key = "forecast_id"
  has_many :forecast_assignments, class_name: "ForecastAssignment", foreign_key: "person_id"

  scope :archived, -> {
    where('data @> ?', {archived: true}.to_json)
  }

  scope :active, -> {
    where.not('data @> ?', {archived: true}.to_json)
  }

  def display_name
    "[#{data['code']}] #{data['name']}"
  end
end
