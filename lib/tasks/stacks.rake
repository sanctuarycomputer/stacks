namespace :stacks do
  desc "Freshen Qbo Token"
  task :refresh_qbo_token => :environment do
    begin
      Stacks::Quickbooks.make_and_refresh_qbo_access_token
      QboAccount.all.map(&:make_and_refresh_qbo_access_token)
    rescue => e
      Sentry.capture_exception(e)
    end
  end

  task :make_notifications => :environment do
    begin
      Stacks::Notifications.make_notifications!
    rescue => e
      Sentry.capture_exception(e)
    end
  end

  desc "Sync Forecast"
  task :sync_forecast => :environment do
    begin
      Stacks::Team.discover!
      Stacks::Forecast.new.sync_all!
    rescue => e
      Sentry.capture_exception(e)
    end
  end

  desc "Sync Expenses"
  task :sync_expenses => :environment do
    begin
      Stacks::Expenses.sync_all! # TODO Remove me?
      Stacks::Expenses.match_all! # TODO Remove me?
    rescue => e
      Sentry.capture_exception(e)
    end
  end

  desc "Sync Biz"
  task :sync_biz => :environment do
    begin
      Stacks::Biz.sync!
    rescue => e
      Sentry.capture_exception(e)
    end
  end

  desc "Sample Social Properties"
  task :sample_social_properties => :environment do
    begin
      SocialProperty.all.each(&:generate_snapshot!)
    rescue => e
      Sentry.capture_exception(e)
    end
  end

  desc "Daily Tasks"
  task :daily_tasks => :environment do
    begin

      puts "~~~> DOING SYNC: #{Time.new.localtime}"
      Stacks::Team.discover!
      Stacks::Forecast.new.sync_all!
      Stacks::Quickbooks.sync_all!

      # TODO: When we start using enterprises, freshen this
      # QboAccount.all.map(&:sync_all!)

      puts "~~~> DOING SNAPSHOTS"
      # Do internal studios first, because their costs are absorbed by client_services studios
      Parallel.map(Studio.internal, in_threads: 2) { |s| s.generate_snapshot! }
      # Next, do reinvestment studios
      Parallel.map(Studio.reinvestment, in_threads: 2) { |s| s.generate_snapshot! }
      # Finally, do client_services, which require data from internal studios 
      # (and garden3d hides reinvestment data)
      Parallel.map(Studio.client_services, in_threads: 2) { |s| s.generate_snapshot! }
      # Now, generate project snapshots
      Parallel.map(ProjectTracker.all, in_threads: 10) { |pt| pt.generate_snapshot! }

      puts "~~~> DOING MISC"
      ProfitSharePass.ensure_exists!
      Stacks::Dei.make_rollup # TODO Remove me

      Stacks::Automator.attempt_invoicing_for_previous_month
      Stacks::Automator.remind_people_to_record_hours_weekly
      Stacks::Notifications.make_notifications!
      Stacks::Notifications.notify_admins_of_outstanding_notifications_every_tuesday!
      puts "~~~> FIN: #{Time.new.localtime}"

    rescue => e
      puts "~~~> ERROR"
      puts e
      puts e.backtrace
      Sentry.capture_exception(e)
    end
  end
end
