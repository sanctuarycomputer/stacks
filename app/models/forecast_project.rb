class ForecastProject < ApplicationRecord
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
