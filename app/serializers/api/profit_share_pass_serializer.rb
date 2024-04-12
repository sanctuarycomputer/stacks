class Api::ProfitSharePassSerializer < ActiveModel::Serializer
  attributes :id, 
  :desired_buffer_months,
  :efficiency_cap,
  :fica_tax_rate,
  :gross_expenses,
  :gross_payroll,
  :gross_revenue,
  :gross_benefits,
  :subcontractors,
  :pre_spent,
  :pre_spent_reinvestment,
  :internals_budget_multiplier,
  :projected_monthly_cost_of_doing_business,
  :total_psu_issued,
  :year

  def desired_buffer_months
    object.snapshot&.dig("inputs", "desired_buffer_months").to_f
  end
  
  def efficiency_cap
    object.snapshot&.dig("inputs", "efficiency_cap").to_f
  end
  
  def fica_tax_rate
    object.snapshot&.dig("inputs", "fica_tax_rate").to_f
  end
  
  def gross_expenses
    object.snapshot&.dig("inputs", "actuals", "gross_expenses").to_f
  end
  
  def gross_payroll
    object.snapshot&.dig("inputs", "actuals", "gross_payroll").to_f
  end
  
  def gross_revenue
    object.snapshot&.dig("inputs", "actuals", "gross_revenue").to_f
  end

  def gross_benefits
    object.snapshot&.dig("inputs", "actuals", "gross_benefits").to_f
  end

  def subcontractors
    object.snapshot&.dig("inputs", "actuals", "gross_subcontractors").to_f
  end

  def pre_spent
    object.snapshot&.dig("inputs", "pre_spent").to_f
  end

  def pre_spent_reinvestment
    object.snapshot&.dig("inputs", "pre_spent_reinvestment").to_f
  end
  
  def internals_budget_multiplier
    object.snapshot&.dig("inputs", "internals_budget_multiplier").to_f
  end
  
  def projected_monthly_cost_of_doing_business
    object.snapshot&.dig("inputs", "projected_monthly_cost_of_doing_business").to_f
  end
  
  def total_psu_issued
    object.total_psu_issued(object.finalization_day).round
  end
  
  def year
    object.created_at.year
  end

end
