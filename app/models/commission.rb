class Commission < ApplicationRecord
  acts_as_paranoid

  belongs_to :project_tracker
  belongs_to :contributor

  validates :type, presence: true
  validates :rate, presence: true, numericality: { greater_than_or_equal_to: 0 }

  # Subclasses MUST implement:
  #   deduction_for_line(qbo_line_item, blueprint_line) -> BigDecimal
  #   description_line(qbo_line_item, blueprint_line, deduction) -> String
  def deduction_for_line(_qbo_line_item, _blueprint_line)
    raise NotImplementedError, "#{self.class} must implement #deduction_for_line"
  end

  def description_line(_qbo_line_item, _blueprint_line, _deduction)
    raise NotImplementedError, "#{self.class} must implement #description_line"
  end

  private

  def n2c(v)
    ActionController::Base.helpers.number_to_currency(v)
  end
end
