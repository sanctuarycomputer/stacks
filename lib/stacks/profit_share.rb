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
    attr_accessor :projected_monthly_cost_of_doing_business
    attr_accessor :fica_tax_rate
    attr_accessor :pre_spent_reinvestment

    # What does 1.6 efficiency_cap mean? Well, it means that for
    # every dollar we spend, we strive to make 1.6 dollars back.
    # That is a margin of 60%, at which a PSU is worth $1000!
    def initialize(
      actuals,
      total_psu_issued,
      pre_spent = 0,
      desired_buffer_months = 1.5,
      efficiency_cap = 1.6,
      internals_budget_multiplier = 0.5,
      projected_monthly_cost_of_doing_business = nil,
      fica_tax_rate = Stacks::ProfitShare::Scenario::FICA_TAX_RATE,
      pre_spent_reinvestment = 0
    )
      @actuals = actuals
      @total_psu_issued = total_psu_issued
      @pre_spent = pre_spent
      @desired_buffer_months = desired_buffer_months
      @efficiency_cap = efficiency_cap
      @internals_budget_multiplier = internals_budget_multiplier
      @projected_monthly_cost_of_doing_business = projected_monthly_cost_of_doing_business
      @fica_tax_rate = fica_tax_rate
      @pre_spent_reinvestment = pre_spent_reinvestment
    end

    def total_cost_of_doing_business
      @actuals[:gross_payroll].to_f +
      @actuals[:gross_expenses].to_f +
      @actuals[:gross_benefits].to_f +
      @actuals[:gross_subcontractors].to_f -
      @pre_spent - # Don't count prespent profit share against this
      @pre_spent_reinvestment # Don't count prespent reinvestment against this
    end

    def projected_monthly_cost_of_doing_business
      return @projected_monthly_cost_of_doing_business if @projected_monthly_cost_of_doing_business.present?
      total_cost_of_doing_business / 12
    end

    def raw_efficiency
      @actuals[:gross_revenue].to_f / total_cost_of_doing_business
    end

    def efficiency
      [
        Stacks::Utils.clamp(
          raw_efficiency,
          1.00,
          @efficiency_cap,
          0,
          1
        ),
        1
      ].min
    end

    def total_profit
      @actuals[:gross_revenue].to_f - total_cost_of_doing_business
    end

    def max_value_per_psu
      efficiency * 1000
    end

    def actual_value_per_psu
      allowances[:pool_after_fica_withholding] / @total_psu_issued
    end

    def allowances
      desired_buffer = (
        projected_monthly_cost_of_doing_business *
        @desired_buffer_months *
        (1 + TAX_RATE)
      )

      desired_internals_budget =
        projected_monthly_cost_of_doing_business * internals_budget_multiplier;
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

          pool_after_fica_withholding = pool / (1 + fica_tax_rate)

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
