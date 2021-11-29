class Stacks::ProfitShare
  class Scenario
    TAX_RATE = 0.36
    FICA_TAX_RATE = 0.0765

    attr_accessor :actuals
    attr_accessor :total_psu_issued
    attr_accessor :desired_buffer_months
    attr_accessor :efficiency_cap
    attr_accessor :pre_spent
    attr_accessor :internals_budget_multiplier

    # What does 1.65 efficiency_cap mean? Well, it means that for
    # every dollar we spend, we strive to make 1.65 dollars back.
    # That is a margin of 65%. In a 5 day work week, taking into
    # account non-billable team members, and expenses like software,
    # healthcare and employer taxes, a person costs us roughly $95
    # per billable hour. In a 4 day work week, that same person will
    # cost us around $126 per billable hour.
    def initialize(
      actuals,
      total_psu_issued,
      pre_spent = 0,
      desired_buffer_months = 1.5,
      efficiency_cap = 1.65,
      internals_budget_multiplier = 0.5
    )
      @actuals = actuals
      @total_psu_issued = total_psu_issued
      @pre_spent = pre_spent
      @desired_buffer_months = desired_buffer_months
      @efficiency_cap = efficiency_cap
      @internals_budget_multiplier = internals_budget_multiplier
    end

    def total_cost_of_doing_business
      @actuals[:gross_payroll] +
      @actuals[:gross_expenses] +
      @actuals[:gross_benefits] +
      @actuals[:gross_subcontractors] -
      @pre_spent # Don't count prespent profit share against this
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
        monthly_cost_of_doing_business * internals_budget_multiplier;
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
