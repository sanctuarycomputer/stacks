class ForecastPersonCostWindow < ApplicationRecord
  belongs_to :forecast_person
  belongs_to :forecast_project

  scope :needs_review, -> {
    where(needs_review: true)
  }
end
