class StepCompletion < ApplicationRecord
  include BustsTaskCache
  SOURCES = %w[self auto admin].freeze

  belongs_to :admin_user
  belongs_to :module_step
  belongs_to :completed_by, class_name: "AdminUser", optional: true

  validates :completed_at, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :module_step_id, uniqueness: { scope: :admin_user_id }
end
