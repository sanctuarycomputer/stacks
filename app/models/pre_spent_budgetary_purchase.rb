class PreSpentBudgetaryPurchase < ApplicationRecord
  belongs_to :budget

  enum budget_type: {
    reinvestment: 0,
    charitable_giving: 1,
  }
end
