class Api::ProfitSharePassSerializer 
  include JSONAPI::Serializer
  attributes :id, :total_psu_issued, :efficiency_cap_from_snapshot, 
  :desired_buffer_months, :gross_revenue, :gross_expenses, :gross_payroll, 
  :projected_monthly_cost_of_doing_business, :fica_tax_rate, :internals_budget_multiplier

  def total_psu_issued
    object.total_psu_issued.round
  end

  def efficiency_cap_from_snapshot
    object.efficiency_cap_from_snapshot
  end

  def desired_buffer_months
    object.desired_buffer_months
  end

  def gross_revenue
    object.gross_revenue
  end

  def gross_expenses
    object.gross_revenue
  end

  def gross_payroll
    object.gross_payroll
  end

  def projected_monthly_cost_of_doing_business
    object.projected_monthly_cost_of_doing_business
  end

  def fica_tax_rate
    object.fica_tax_rate
  end

  def internals_budget_multiplier
    object.internals_budget_multiplier
  end

end
