class Course < ApplicationRecord
  belongs_to :qualification, optional: true
  has_many :course_modules, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :course
  has_many :learning_modules, through: :course_modules
  has_many :course_assignments, dependent: :restrict_with_error
  accepts_nested_attributes_for :course_modules, allow_destroy: true

  validates :name, :slug, presence: true, uniqueness: true
  validates :learner_title, presence: true
  validates :grace_period_days, numericality: { only_integer: true, greater_than_or_equal_to: 1 }

  scope :auto_assigned, -> { where(auto_assign: true) }

  def ordered_modules
    course_modules.includes(:learning_module).map(&:learning_module)
  end

  def display_name
    name
  end
end
