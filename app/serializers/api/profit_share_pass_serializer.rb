class Api::ProfitSharePassSerializer < ActiveModel::Serializer
  attributes :id, :total_psu_issued, :efficiency_cap_from_snapshot, 
  :desired_buffer_months, :gross_revenue, :gross_expenses, :gross_payroll, 
  :projected_monthly_cost_of_doing_business, :fica_tax_rate, :internals_budget_multiplier, :year

  def year
    object.created_at.year
  end

  def total_psu_issued
    object.total_psu_issued.round
  end

  def efficiency_cap_from_snapshot
    object.efficiency_cap_from_snapshot.to_f
  end

  def desired_buffer_months
    object.desired_buffer_months.to_f
  end

  def gross_revenue
    object.gross_revenue.to_f
  end

  def gross_expenses
    object.gross_expenses.to_f
  end

  def gross_payroll
    object.gross_payroll.to_f
  end

  def projected_monthly_cost_of_doing_business
    object.projected_monthly_cost_of_doing_business.to_f
  end

  def fica_tax_rate
    object.fica_tax_rate.to_f
  end

  def internals_budget_multiplier
    object.internals_budget_multiplier.to_f
  end

end
