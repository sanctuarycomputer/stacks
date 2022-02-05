namespace :stacks do
  desc "Generate Invoices"
  task :attempt_generate_invoices => :environment do
    Stacks::Automator.attempt_invoicing_for_previous_month
  end

  desc "Freshen Qbo Token"
  task :refresh_qbo_token => :environment do
    Stacks::Automator.make_and_refresh_qbo_access_token
  end

  desc "Run Profitability Rollup"
  task :run_profitability_rollup => :environment do
    Stacks::Profitability.calculate
  end

  desc "Daily Tasks"
  task :daily_tasks => :environment do
    ProfitSharePass.ensure_exists!
    Stacks::Dei.make_rollup
    Stacks::Utilization.calculate
    Stacks::Forecast.new.sync_all!
    Stacks::Expenses.sync_all!
    Stacks::Expenses.match_all!
  end

  desc "Seed Operations"
  task :seed_operations => :environment do
    o = Tree.create!(name: "Operations")
    Trait.create!(name: "People", tree: o)
    Trait.create!(name: "Process", tree: o)
    Trait.create!(name: "Finances", tree: o)
    Trait.create!(name: "Offering Knowledge", tree: o)
    Trait.create!(name: "Business Development", tree: o)
  end

  desc "Seed Studios"
  task :seed_studios => :environment do
    Studio.create!(name: "XXIX", accounting_prefix: "Brand Services", mini_name: "xxix")
    Studio.create!(name: "Manhattan Hydraulics", accounting_prefix: "UX Services", mini_name: "hydro")
    Studio.create!(name: "Sanctuary Computer", accounting_prefix: "Development Services", mini_name: "sanctu")
    Studio.create!(name: "Index", accounting_prefix: "Community Services", mini_name: "index")
  end

  desc "Seed Previous Profit Shares"
  task :seed_profit_shares => :environment do
    h = AdminUser.where(email: "hugh@sanctuary.computer").first
    h.update!(roles: h.roles << "profit_share_manager")
    ProfitSharePass.ensure_exists!

    # 2020
    ProfitSharePass.create!(
      created_at: DateTime.new(2020, 1, 1),
      snapshot: {
        finalized_at: DateTime.new(2020, 12, 15),
        inputs: {
          actuals: {
            gross_revenue: 2776966.19,
            gross_payroll: 1974151.47,
            gross_expenses: 241859.05,
            gross_benefits: 0,
            gross_subcontractors: 0,
          },
          total_psu_issued: 427,
          pre_spent: 0,
          desired_buffer_months: 1,
          efficiency_cap: 1.6,
          internals_budget_multiplier: 0.3,
          projected_monthly_cost_of_doing_business: 221934.96,
          fica_tax_rate: 0.0765
        }
      }
    )

    # 2019
    ProfitSharePass.create!(
      created_at: DateTime.new(2019, 1, 1),
      snapshot: {
        finalized_at: DateTime.new(2019, 12, 15),
        inputs: {
          actuals: {
            gross_revenue: 1776824.28,
            gross_payroll: 1010991.09,
            gross_expenses: 324060.21,
            gross_benefits: 0,
            gross_subcontractors: 0,
          },
          total_psu_issued: 250,
          pre_spent: 0,
          desired_buffer_months: 1,
          efficiency_cap: 1.75,
          internals_budget_multiplier: 0.5,
          projected_monthly_cost_of_doing_business: 111701.16,
          fica_tax_rate: 0.0765
        }
      }
    )

    # 2018
    ProfitSharePass.create!(
      created_at: DateTime.new(2018, 1, 1),
      snapshot: {
        finalized_at: DateTime.new(2018, 12, 15),
        inputs: {
          actuals: {
            gross_revenue: 1168836,
            gross_payroll: 653351,
            gross_expenses: 304610,
            gross_benefits: 0,
            gross_subcontractors: 0,
          },
          total_psu_issued: 139,
          pre_spent: 0,
          desired_buffer_months: 1,
          efficiency_cap: 1.6,
          internals_budget_multiplier: 0.5,
          projected_monthly_cost_of_doing_business: 84000,
          fica_tax_rate: 0
        }
      }
    )

    # 2017
    ProfitSharePass.create!(
      created_at: DateTime.new(2017, 1, 1),
      snapshot: {
        finalized_at: DateTime.new(2017, 12, 15),
        inputs: {
          actuals: {
            gross_revenue: 614008.84,
            gross_payroll: 346502.51,
            gross_expenses: 132485.05,
            gross_benefits: 0,
            gross_subcontractors: 0,
          },
          total_psu_issued: 84,
          pre_spent: 0,
          desired_buffer_months: 1,
          efficiency_cap: 1.9,
          internals_budget_multiplier: 0.5,
          projected_monthly_cost_of_doing_business: 28750,
          fica_tax_rate: 0
        }
      }
    )
  end
end
