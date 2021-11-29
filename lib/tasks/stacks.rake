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
end
