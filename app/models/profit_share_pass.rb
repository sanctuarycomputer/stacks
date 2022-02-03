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

  def prespent
    (PreProfitSharePurchase.where(
      purchased_at: Date.new(created_at.year).beginning_of_year..Date.new(created_at.year).end_of_year
    ).map(&:amount).reduce(:+) || 0.0)
  end

  def finalization_day
    Date.new(created_at.year, 12, 15)
  end

  def make_scenario
    if finalized?
      Stacks::ProfitShare::Scenario.new(
        snapshot["inputs"]["actuals"].symbolize_keys,
        snapshot["inputs"]["total_psu_issued"].to_f,
        snapshot["inputs"]["pre_spent"].to_f,
        snapshot["inputs"]["desired_buffer_months"].to_f,
        snapshot["inputs"]["efficiency_cap"].to_f,
        snapshot["inputs"]["internals_budget_multiplier"].to_f,
        snapshot["inputs"]["projected_monthly_cost_of_doing_business"].to_f,
        snapshot["inputs"]["fica_tax_rate"].to_f
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
            outstanding.filter{|iv| iv.due_date <= Date.today.end_of_year && iv.due_date >= Date.today.beginning_of_year}.map(&:balance).reduce(:+)
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

      Stacks::ProfitShare::Scenario.new(
        actuals,
        AdminUser.total_projected_psu_issued_by_eoy,
        self.prespent,
        self.payroll_buffer_months,
        self.efficiency_cap,
        self.internals_budget_multiplier,
        projected_monthly_cost_of_doing_business,
        Stacks::ProfitShare::Scenario::FICA_TAX_RATE
      )
    end
  end
end
