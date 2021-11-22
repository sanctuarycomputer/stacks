class Stacks::ProfitShare
  class << self
    def latest_scenario
      latest_pass =
        ProfitabilityPass.order(created_at: :desc).first

      Stacks::ProfitShare::Scenario.new(
        Stacks::ProfitShare.make_actuals_projections(latest_pass),
        AdminUser.total_projected_psu_issued_by_eoy,
      )
    end

    def make_actuals_projections(profitability_pass)
      latest_data =
        profitability_pass.data["garden3d"][Time.now.year.to_s]
      ytd = latest_data.values.reduce({}) do |acc, v|
        acc["gross_payroll"] =
          (acc["gross_payroll"] || 0.0) + (v["gross_payroll"].to_f || 0.0)
        acc["gross_revenue"] =
          (acc["gross_revenue"] || 0.0) + (v["gross_revenue"].to_f || 0.0)
        acc["gross_benefits"] =
          (acc["gross_benefits"] || 0.0) + (v["gross_benefits"].to_f || 0.0)
        acc["gross_expenses"] =
          (acc["gross_expenses"] || 0.0) + (v["gross_expenses"].to_f || 0.0)
        acc["gross_subcontractors"] =
          (acc["gross_subcontractors"] || 0.9) + (v["gross_subcontractors"].to_f || 0.0)
        acc
      end

      months_passed = latest_data.keys.length
      projection = {
        "gross_payroll": (ytd["gross_payroll"] / months_passed) * 12,
        "gross_revenue": (ytd["gross_revenue"] / months_passed) * 12,
        "gross_benefits": (ytd["gross_benefits"] / months_passed) * 12,
        "gross_expenses": (ytd["gross_expenses"] / months_passed) * 12,
        "gross_subcontractors": (ytd["gross_subcontractors"] / months_passed) * 12,
      }
    end
  end

  class Scenario
    TAX_RATE = 0.36
    FICA_TAX_RATE = 0.0765
    INTERNALS_BUDGET_MULTIPLIER = 0.5

    attr_accessor :actuals
    attr_accessor :total_psu_issued
    attr_accessor :desired_buffer_months
    attr_accessor :efficiency_cap

    def initialize(
      actuals,
      total_psu_issued,
      desired_buffer_months = 2,
      efficiency_cap = 1.75
    )
      @actuals = actuals
      @total_psu_issued = total_psu_issued
      @desired_buffer_months = desired_buffer_months
      @efficiency_cap = efficiency_cap
    end

    def total_cost_of_doing_business
      @actuals[:gross_payroll] +
      @actuals[:gross_expenses] +
      @actuals[:gross_benefits] +
      @actuals[:gross_subcontractors]
    end

    def monthly_cost_of_doing_business
      total_cost_of_doing_business / 12
    end

    def raw_efficiency
      @actuals[:gross_revenue] / total_cost_of_doing_business
    end

    def efficiency
      Stacks::Utils.clamp(
        raw_efficiency,
        1.00,
        @efficiency_cap,
        0,
        1
      )
    end

    def total_profit
      @actuals[:gross_revenue] - total_cost_of_doing_business
    end

    def max_value_per_psu
      efficiency * 1000
    end

    def actual_value_per_psu
      allowances[:pool_after_fica_withholding] / @total_psu_issued
    end

    def allowances
      desired_buffer = (
        monthly_cost_of_doing_business *
        @desired_buffer_months *
        (1 + TAX_RATE)
      )

      desired_internals_budget =
        monthly_cost_of_doing_business * INTERNALS_BUDGET_MULTIPLIER;
      max_pool_before_reinvestment =
        @total_psu_issued * max_value_per_psu

      if total_profit >= desired_buffer
        if ((total_profit - desired_buffer) >= desired_internals_budget)
          # We made enough to afford both a payroll buffer, and
          # studio upgrades for the following year. Best scenario!
          pool = total_profit - desired_buffer - desired_internals_budget
          reinvestment_budget = 0

          if pool > max_pool_before_reinvestment
            reinvestment_budget = pool - max_pool_before_reinvestment
            pool = max_pool_before_reinvestment
          end

          pool_after_fica_withholding = pool / (1 + FICA_TAX_RATE)

          return {
            buffer: desired_buffer,
            internals_budget: desired_internals_budget,
            pool: pool,
            fica_withholding: (pool - pool_after_fica_withholding),
            pool_after_fica_withholding: pool_after_fica_withholding,
            reinvestment_budget: reinvestment_budget
          }
        end

        return {
          buffer: desired_buffer,
          internals_budget: total_profit - desired_buffer,
          pool: 0,
          fica_withholding: 0,
          pool_after_fica_withholding: 0,
          reinvestment_budget: 0
        }
      end

      return {
        buffer: total_profit,
        internals_budget: 0,
        pool: 0,
        fica_withholding: 0,
        pool_after_fica_withholding: 0,
        reinvestment_budget: 0
      }
    end
  end
end
