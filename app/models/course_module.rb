class CourseModule < ApplicationRecord
  belongs_to :course
  belongs_to :learning_module

  validates :learning_module_id, uniqueness: { scope: :course_id }
  validates :position, numericality: { only_integer: true }
end
