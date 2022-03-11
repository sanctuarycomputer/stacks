namespace :stacks do
  desc "Freshen Qbo Token"
  task :refresh_qbo_token => :environment do
    Stacks::Automator.make_and_refresh_qbo_access_token
  end

  desc "Daily Tasks"
  task :daily_tasks => :environment do
    Stacks::Team.discover!
    Stacks::Forecast.new.sync_all!
    Stacks::Expenses.sync_all!
    Stacks::Expenses.match_all!

    Stacks::Profitability.calculate
    ProfitSharePass.ensure_exists!
    Stacks::Dei.make_rollup
    Stacks::Utilization.calculate

    Stacks::Automator.attempt_invoicing_for_previous_month
    Stacks::Notifications.notify_admins_of_outstanding_notifications_every_tuesday!
  end
end
