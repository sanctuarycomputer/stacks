# The atomic unit: an ordered list of steps plus an optional quiz. Named
# LearningModule because Module is a Ruby core class. A module can sit in
# several courses; a person's progress through it is shared between them.
class LearningModule < ApplicationRecord
  belongs_to :qualification, optional: true
  has_many :course_modules, dependent: :restrict_with_error
  has_many :courses, through: :course_modules
  has_many :module_steps, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :learning_module
  has_many :quiz_questions, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :learning_module
  has_many :quiz_attempts, dependent: :restrict_with_error
  has_many :quiz_retry_grants, dependent: :restrict_with_error
  has_many :module_completions, dependent: :restrict_with_error
  accepts_nested_attributes_for :module_steps, allow_destroy: true
  accepts_nested_attributes_for :quiz_questions, allow_destroy: true

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :quiz_pass_percent, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }

  # dependent: :destroy and nested _destroy both call destroy! on each step, so
  # ModuleStep's restrict_with_error would surface as RecordNotDestroyed (a 500
  # in the admin form). Refuse cleanly up front instead.
  validate :no_completed_step_marked_for_destruction
  before_destroy :refuse_destroy_when_steps_have_completions, prepend: true

  def display_name
    name
  end

  private

  def no_completed_step_marked_for_destruction
    doomed = module_steps.select(&:marked_for_destruction?).select { |step| step.step_completions.exists? }
    return if doomed.empty?
    errors.add(:base, "Can't remove a step people have completed: #{doomed.map(&:title).join(", ")}")
  end

  def refuse_destroy_when_steps_have_completions
    return unless StepCompletion.where(module_step_id: module_steps.select(:id)).exists?
    errors.add(:base, "People have progress on this module")
    throw :abort
  end
end
