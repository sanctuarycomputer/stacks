class Budget < ApplicationRecord
  has_many :pre_spent_budgetary_purchases

  def spent
    pre_spent_budgetary_purchases.map(&:amount).reduce(:+) || 0
  end

  enum budget_type: {
    reinvestment: 0,
    charitable_giving: 1,
  }
end
