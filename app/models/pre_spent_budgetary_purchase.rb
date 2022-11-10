class PreSpentBudgetaryPurchase < ApplicationRecord
  enum budget_type: {
    reinvestment: 0,
    charitable_giving: 1,
  }
end
