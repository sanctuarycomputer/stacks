namespace :stacks do
  desc "Freshen Qbo Token"
  task :refresh_qbo_token => :environment do
    begin
      Stacks::Quickbooks.make_and_refresh_qbo_access_token
    rescue => e
      Sentry.capture_exception(e)
    end
  end

  desc "Freshen Enterprise Qbo Tokens"
  task :refresh_enterprise_qbo_tokens => :environment do
    begin
      QboAccount.all.map(&:make_and_refresh_qbo_access_token)
    rescue => e
      Sentry.capture_exception(e)
    end
  end

  desc "Daily Enterprise Tasks"
  task :daily_enterprise_tasks => :environment do
    Parallel.map(QboAccount.all, in_threads: 2) { |e| e.sync_all! }
    Parallel.map(Enterprise.all, in_threads: 2) { |e| e.generate_snapshot! }
  end

  desc "Make Notifications"
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

  desc "Sync Notion"
  task :sync_notion => :environment do
    begin
      notion = Stacks::Notion.new
      Parallel.map(Stacks::Notion::DATABASE_IDS.values, in_threads: 3) do |db_id|
        notion.sync_database(db_id)
      end
      Stacks::Automator.send_stale_task_digests_every_thursday
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

  desc "Sync Contacts"
  task :sync_contacts => :environment do
    begin
      Contact.all.each(&:dedupe!)

      # First ensure that any new mailing list subscribers have a Contact record
      MailingList.includes(:mailing_list_subscribers).each do |ml|
        ml.mailing_list_subscribers.each do |sub|
          contact = Contact.create_or_find_by!(email: sub.email.downcase)
          contact.update(sources: [*contact.sources, "#{ml.studio.mini_name}:#{ml.provider}:#{ml.name.parameterize(separator: '_')}"].uniq)
        end
      end

      # Sync each contact to Apollo
      apollo = Stacks::Apollo.new
      already_synced = Contact.where.not(apollo_id: nil).order("updated_at ASC")

      # Apollo API free plan only allows 50 requests per minute, 200 per hour, and 600 per day,
      # so I'll schedule this 3 times per day and it will eventually sync all contacts over.
      Contact.where(apollo_id: nil).each do |c|
        c.sync_to_apollo!(apollo)
        sleep 1.5
      end

      # We got through all the sync'd contacts, so let's freshen the data on the existing
      # synced contacts
      already_synced.each do |c|
        c.sync_to_apollo!(apollo)
        sleep 1.5
      end
    rescue => e
      puts e
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
      Stacks::DailyFinancialSnapshotter.snapshot_all!

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

  desc "Resync salary windows"
  task :resync_salary_windows => :environment do
    begin
      AdminUser.all.each(&:sync_salary_windows!)
    rescue => e
      Sentry.capture_exception(e)
    end
  end
end
