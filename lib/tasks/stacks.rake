namespace :stacks do
  desc "Freshen Qbo Token"
  task :refresh_qbo_token => :environment do
    Stacks::Automator.make_and_refresh_qbo_access_token
  end

  desc "Daily Tasks"
  task :daily_tasks => :environment do
    Stacks::Profitability.calculate
    Stacks::Automator.attempt_invoicing_for_previous_month
    ProfitSharePass.ensure_exists!
    Stacks::Dei.make_rollup
    Stacks::Utilization.calculate
    Stacks::Forecast.new.sync_all!
    Stacks::Expenses.sync_all!
    Stacks::Expenses.match_all!
    Stacks::Team.discover!
  end
end
