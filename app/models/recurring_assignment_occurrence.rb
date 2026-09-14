class RecurringAssignmentOccurrence < ApplicationRecord
  STATUSES = %w[materialized deleted].freeze

  belongs_to :recurring_assignment

  validates :occurs_on, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :materialized, -> { where(status: "materialized") }
  scope :deleted, -> { where(status: "deleted") }
end
