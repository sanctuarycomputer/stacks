class CourseAssignment < ApplicationRecord
  include BustsTaskCache

  belongs_to :admin_user
  belongs_to :course
  belongs_to :assigned_by, class_name: "AdminUser", optional: true
  belongs_to :waived_by, class_name: "AdminUser", optional: true

  before_validation :apply_date_defaults, on: :create

  # So a new checklist shows what Stacks already knows (Forecast account,
  # payment profile). After commit, and rescued: a refresh failure must never
  # undo or block the assignment itself.
  after_create_commit :refresh_progress

  validates :assigned_on, :due_on, presence: true
  validates :course_id, uniqueness: { scope: :admin_user_id, message: "is already assigned to this person" }

  scope :outstanding, -> { where(completed_at: nil, waived_at: nil) }

  def outstanding?
    completed_at.nil? && waived_at.nil?
  end

  def completed?
    completed_at.present?
  end

  def waived?
    waived_at.present?
  end

  def display_name
    "#{admin_user&.email} — #{course&.name}"
  end

  private

  def refresh_progress
    Stacks::Learning::Progress.refresh!(admin_user)
  rescue => e
    Rails.logger.error("CourseAssignment##{id} initial refresh failed: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end

  def apply_date_defaults
    self.assigned_on ||= Date.today
    self.due_on ||= assigned_on + course.grace_period_days if course
  end
end
