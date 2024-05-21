class ForecastAssignmentDailyFinancialSnapshot < ApplicationRecord
  belongs_to :forecast_assignment

  scope :needs_review, -> {
    where(needs_review: true)
  }
end
