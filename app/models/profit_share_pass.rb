# TODO: Ability to "finalize" & "unfinalize"
# TODO: Can't finalize unless Rollup has december and it's after December 15th
# TODO: Bring over all profit share passes historically
# TODO: Bring over projectedLaborCost

# N2H
# TODO: add charity budgets?
# TODO: PSU value over the years
# TODO: Gross Revenue over the years
# TODO: Don't show projections to non-profit-share managers until there's 6 months of data

class ProfitSharePass < ApplicationRecord
  scope :this_year, -> {
    where(created_at: Time.now.beginning_of_year..Time.now.end_of_year)
  }

  def display_name
    "#{created_at.year} Profit Share"
  end

  def finalize!
    #attrs: {
    #  efficiencyCap: 1.6, # On model
    #  desiredPayrollBufferMonths: 1, # On model
    #  income: 2776966.19, # gross_revenue
    #  expenses: 241859.05, # gross_expenses
    #  actualLaborCost: 1974151.47, # gross_benefits + gross_payroll + gross_subcontractors
    #  projectedLaborCost: 2663219.52, # TODO december's labor cost * 12
    #  actualTotalPSUIssued: 427, # total_psu_issued
    #  ficaPercentage: 0.0765, # FICA Percentage
    #  internalsBudgetMultiplier: 0.3 # TODO: internals_budget_multiplier should be configurable
    #  # corporate_tax_percentage
    #}
    #

    actuals = Stacks::Profitability.pull_actuals_for_year(created_at.year)
    scenario = Stacks::ProfitShare::Scenario.new(
      actuals,
      AdminUser.total_projected_psu_issued_by_eoy,
      prespent,
      payroll_buffer_months,
      efficiency_cap,
      internals_budget_multiplier
    )

    # TODO pre_spent_profit_share
    {
      inputs: {
        actuals: scenario.actuals,
        total_psu_issued: scenario.total_psu_issued,
        pre_spent: scenario.pre_spent,
        controls: {
          efficiency_cap: scenario.effiency_cap,
          payroll_buffer_months: scenario.payroll_buffer_months,
          internals_budget_multiplier: scenario.internals_budget_multiplier,
          fica: scenario.class::TAX_RATE,
          corporate: scenario.class::FICA_TAX_RATE,
        },
      },
      outputs: {
        total_cost_of_doing_business: scenario.total_cost_of_doing_business,
        raw_efficiency: scenario.raw_efficiency,
        efficiency: scenario.efficiency,
        actual_value_per_psu: scenario.actual_value_per_psu
        allowances: scenario.allowances,
      }
    }

    # Make snapshot
    # Mark as Finalized
  end

  def self.ensure_exists!
    return ProfitSharePass.this_year.first if ProfitSharePass.this_year.any?
    ProfitSharePass.create!
  end

  def is_projection?
    finalized_at.nil?
  end

  def prespent
    (PreProfitSharePurchase.where(
      purchased_at: Date.new(created_at.year).beginning_of_year..Date.new(created_at.year).end_of_year
    ).map(&:amount).reduce(:+) || 0.0)
  end

  def make_projection
    latest_pass =
      ProfitabilityPass.order(created_at: :desc).first
    actuals =
      Stacks::Profitability.make_actuals_projections(latest_pass, created_at.year)

    Stacks::ProfitShare::Scenario.new(
      actuals,
      AdminUser.total_projected_psu_issued_by_eoy,
      prespent,
      payroll_buffer_months,
      efficiency_cap,
      internals_budget_multiplier
    )
  end
end
