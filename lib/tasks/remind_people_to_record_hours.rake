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
end
