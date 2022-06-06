namespace :stacks do
  desc "Freshen Qbo Token"
  task :refresh_qbo_token => :environment do
    Stacks::Quickbooks.make_and_refresh_qbo_access_token
  end

  desc "Daily Tasks"
  task :daily_tasks => :environment do
    Stacks::Team.discover!
    Stacks::Forecast.new.sync_all!
    Stacks::Quickbooks.sync_all!
    Stacks::Calendars.sync_all!
    Stacks::Expenses.sync_all! # TODO Remove me
    Stacks::Expenses.match_all! # TODO Remove me

    ProjectTracker.all.each(&:generate_snapshot!)
    ProfitSharePass.ensure_exists!
    Stacks::Dei.make_rollup # TODO Remove me

    Stacks::Automator.attempt_invoicing_for_previous_month
    Stacks::Notifications.notify_admins_of_outstanding_notifications_every_tuesday!
  end
end
