class CourseAssignment < ApplicationRecord
  include BustsTaskCache

  belongs_to :admin_user
  belongs_to :course
  belongs_to :assigned_by, class_name: "AdminUser", optional: true
  belongs_to :waived_by, class_name: "AdminUser", optional: true

  before_validation :apply_date_defaults, on: :create

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

  def apply_date_defaults
    self.assigned_on ||= Date.today
    self.due_on ||= assigned_on + course.grace_period_days if course
  end
end
