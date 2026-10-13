class QuizQuestion < ApplicationRecord
  belongs_to :learning_module

  validates :prompt, presence: true
  validates :position, numericality: { only_integer: true }
  validate :choices_are_well_formed

  # One choice per line, for the admin form.
  def choices_text
    Array(choices).join("\n")
  end

  def choices_text=(text)
    self.choices = text.to_s.lines.map(&:strip).reject(&:blank?)
  end

  private

  def choices_are_well_formed
    list = choices
    unless list.is_a?(Array) && list.size.between?(2, 6) && list.all? { |c| c.is_a?(String) && c.present? }
      errors.add(:choices, "must be 2 to 6 non-blank choices")
      return
    end
    unless correct_index.is_a?(Integer) && correct_index.between?(0, list.size - 1)
      errors.add(:correct_index, "must point at one of the choices (0 is the first)")
    end
  end
end
