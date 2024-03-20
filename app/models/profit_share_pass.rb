class ProfitSharePass < ApplicationRecord
  def self.this_year
    ProfitSharePass.all.select{|p| p.created_at.year == Time.now.year}
  end

  scope :finalized , -> {
    ProfitSharePass.where.not(snapshot: nil)
  }

  def display_name
    "#{created_at.year} Profit Share"
  end

  def finalized?
    snapshot.present?
  end

  def finalized_at
    snapshot && DateTime.parse(snapshot["finalized_at"])
  end

  def finalize!(scenario)
    update!(snapshot: {
      finalized_at: DateTime.now,
      inputs: {
        actuals: scenario.actuals,
        total_psu_issued: scenario.total_psu_issued,
        pre_spent: scenario.pre_spent,
        desired_buffer_months: scenario.desired_buffer_months,
        efficiency_cap: scenario.efficiency_cap,
        internals_budget_multiplier: scenario.internals_budget_multiplier,
        projected_monthly_cost_of_doing_business: scenario.projected_monthly_cost_of_doing_business,
        fica_tax_rate: scenario.fica_tax_rate,
        pre_spent_reinvestment: scenario.pre_spent_reinvestment
      }
    })
  end

  def self.ensure_exists!
    return ProfitSharePass.this_year.first if ProfitSharePass.this_year.any?
    ProfitSharePass.create!
  end

  def is_projection?
    !finalized?
  end

  def prespent_profit_share
    (PreProfitSharePurchase.where(
      purchased_at: Date.new(created_at.year).beginning_of_year..Date.new(created_at.year).end_of_year
    ).map(&:amount).reduce(:+) || 0.0)
  end

  def net_revenue_by_reinvestment_studio(accounting_method = "cash")
    @_net_revenue_by_reinvestment_studio ||= (
      Studio.reinvestment.reduce({}) do |acc, studio|
        acc[studio] = {
          net_revenue: studio.net_revenue(accounting_method)
        }
        acc
      end
    )
  end

  def total_reinvestment_spend(accounting_method = "cash")
    net_revenue_by_reinvestment_studio(accounting_method).reduce(0) do |acc, tuple|
      studio, data = tuple
      acc += data[:net_revenue].abs if data[:net_revenue].present? && data[:net_revenue] < 0
      acc
    end
  end

  def finalization_day
    Date.new(created_at.year, 12, 15)
  end

  def payments(scenario = make_scenario)
    return [] unless finalized? || (Date.today >= finalization_day)
    psu_value = scenario.actual_value_per_psu

    Studio.garden3d.core_members_active_on(finalization_day).map do |a|
      psu_earnt = a.psu_earned_by(finalization_day)
      psu_earnt = 0 if psu_earnt == nil
      pre_spent_profit_share = a.pre_profit_share_spent_during(finalization_day.year)
      {
        admin_user: a,
        psu_value: psu_value,
        psu_earnt: psu_earnt,
        pre_spent_profit_share: pre_spent_profit_share,
        total_payout: (psu_value * psu_earnt) - pre_spent_profit_share
      }
    end
  end

  def total_psu_issued
    total_psu_issued = Studio.garden3d.core_members_active_on(finalization_day).map{|a| a.psu_earned_by(finalization_day) }.reject{|v| v == nil}.reduce(:+) || 0

    total_psu_issued.round()
  end 

  def make_scenario(
    gross_revenue_override = nil,
    gross_payroll_override = nil,
    gross_benefits_override = nil,
    gross_expenses_override = nil,
    gross_subcontractors_override = nil
  )
    if finalized?
      Stacks::ProfitShare::Scenario.new(
        snapshot["inputs"]["actuals"].symbolize_keys,
        snapshot["inputs"]["total_psu_issued"].to_f,
        snapshot["inputs"]["pre_spent"].to_f,
        snapshot["inputs"]["desired_buffer_months"].to_f,
        snapshot["inputs"]["efficiency_cap"].to_f,
        snapshot["inputs"]["internals_budget_multiplier"].to_f,
        snapshot["inputs"]["projected_monthly_cost_of_doing_business"].to_f,
        snapshot["inputs"]["fica_tax_rate"].to_f,
        snapshot["inputs"]["pre_spent_reinvestment"].to_f
      )
    else
      ytd = Stacks::Profitability.pull_actuals_for_year(created_at.year)
      latest_month = Stacks::Profitability.pull_actuals_for_latest_month

      projected_monthly_cost_of_doing_business = (
        latest_month[:gross_payroll] +
        latest_month[:gross_expenses] +
        latest_month[:gross_benefits] +
        latest_month[:gross_subcontractors]
      )

      days_elapsed = Date.today.yday
      days_this_year = finalization_day.yday

      actuals =
        if Date.today >= finalization_day
          outstanding = Stacks::Profitability.pull_outstanding_invoices
          remaining_revenue_due_this_year =
            outstanding.filter{|iv| (iv.due_date <= Date.today.end_of_year + 15.days) && iv.due_date >= Date.today.beginning_of_year}.map(&:balance).reduce(:+)
          ytd[:gross_revenue] += remaining_revenue_due_this_year
          ytd
        else
          {
            gross_payroll: (ytd[:gross_payroll] / days_elapsed) * days_this_year,
            gross_revenue: (ytd[:gross_revenue] / days_elapsed) * days_this_year,
            gross_benefits: (ytd[:gross_benefits] / days_elapsed) * days_this_year,
            gross_expenses: (ytd[:gross_expenses] / days_elapsed) * days_this_year,
            gross_subcontractors: (ytd[:gross_subcontractors] / days_elapsed) * days_this_year,
          }
        end
      
      # Override for projections
      actuals[:gross_revenue] = gross_revenue_override.to_f if gross_revenue_override.present?
      actuals[:gross_payroll] = gross_payroll_override.to_f if gross_payroll_override.present?
      actuals[:gross_benefits] = gross_benefits_override.to_f if gross_benefits_override.present?
      actuals[:gross_expenses] = gross_expenses_override.to_f if gross_expenses_override.present?
      actuals[:gross_subcontractors] = gross_subcontractors_override.to_f if gross_subcontractors_override.present?

      total_psu_issued =   
        Studio.garden3d.core_members_active_on(finalization_day).map{|a| a.projected_psu_by_eoy }.reject{|v| v == nil}.reduce(:+) || 0

      Stacks::ProfitShare::Scenario.new(
        actuals,
        total_psu_issued,
        self.prespent_profit_share,
        self.payroll_buffer_months,
        self.efficiency_cap,
        self.internals_budget_multiplier,
        projected_monthly_cost_of_doing_business,
        Stacks::ProfitShare::Scenario::FICA_TAX_RATE,
        total_reinvestment_spend("cash")
      )
    end
  end
end
