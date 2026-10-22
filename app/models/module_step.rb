class ModuleStep < ApplicationRecord
  KINDS = %w[read do auto_check admin_sign_off].freeze

  belongs_to :learning_module
  has_many :step_completions, dependent: :restrict_with_error

  validates :title, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :position, numericality: { only_integer: true }
  validates :auto_check_key, inclusion: { in: ->(_) { Stacks::Learning::AutoChecks.keys } }, if: -> { kind == "auto_check" }
  validates :auto_check_key, absence: true, unless: -> { kind == "auto_check" }

  before_validation { self.auto_check_key = auto_check_key.presence }
end
