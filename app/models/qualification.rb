# Something a person can hold: a "qualification" (granted by finishing a
# course) or a "badge" (granted by finishing a module). Nothing expires and
# nothing is unlocked by holding one.
class Qualification < ApplicationRecord
  KINDS = %w[qualification badge].freeze

  has_many :qualification_grants, dependent: :restrict_with_error
  has_many :courses, dependent: :restrict_with_error
  has_many :learning_modules, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }

  def display_name
    name
  end
end
