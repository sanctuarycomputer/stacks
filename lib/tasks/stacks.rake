namespace :stacks do
  desc "Freshen Qbo Token"
  task :refresh_qbo_token => :environment do
    system_task = SystemTask.create!(name: "stacks:refresh_qbo_token")
    begin
      Stacks::Quickbooks.make_and_refresh_qbo_access_token
    rescue => e
      system_task.mark_as_error(e)
    else
      system_task.mark_as_success
    end
  end

  desc "Freshen Enterprise Qbo Tokens"
  task :refresh_enterprise_qbo_tokens => :environment do
    system_task = SystemTask.create!(name: "stacks:refresh_enterprise_qbo_tokens")
    begin
      QboAccount.all.map(&:make_and_refresh_qbo_access_token)
    rescue => e
      system_task.mark_as_error(e)
    else
      system_task.mark_as_success
    end
  end

  desc "Daily Enterprise Tasks"
  task :daily_enterprise_tasks => :environment do
    system_task = SystemTask.create!(name: "stacks:daily_enterprise_tasks")
    begin
      Parallel.map(QboAccount.all, in_threads: 2) { |e| e.sync_all! }
      Parallel.map(Enterprise.all, in_threads: 2) { |e| e.generate_snapshot! }
    rescue => e
      system_task.mark_as_error(e)
    else
      system_task.mark_as_success
    end
  end

  desc "Sync Forecast"
  task :sync_forecast => :environment do
    system_task = SystemTask.create!(name: "stacks:sync_forecast")
    begin
      Stacks::Team.discover!
      Stacks::Forecast.new.sync_all!
    rescue => e
      system_task.mark_as_error(e)
    else
      system_task.mark_as_success
    end
  end

  desc "Sync Runn"
  task :sync_runn => :environment do
    system_task = SystemTask.create!(name: "stacks:sync_runn")
    begin
      Stacks::Runn.new.sync_all!
    rescue => e
      system_task.mark_as_error(e)
    else
      system_task.mark_as_success
    end
  end

  desc "Sync Notion"
  task :sync_notion => :environment do
    system_task = SystemTask.create!(name: "stacks:sync_notion")
    begin
      notion = Stacks::Notion.new
      Parallel.map(Stacks::Notion::DATABASE_IDS.values, in_threads: 3) do |db_id|
        notion.sync_database(db_id)
      end
      Stacks::Automator.send_stale_task_digests_every_thursday
    rescue => e
      system_task.mark_as_error(e)
    else
      system_task.mark_as_success
    end
  end

  desc "Sync Github"
  task :sync_github => :environment do
    system_task = SystemTask.create!(name: "stacks:sync_github")
    begin
      Stacks::Github.sync_all!
      Stacks::Zenhub.sync_all!
    rescue => e
      system_task.mark_as_error(e)
    else
      system_task.mark_as_success
    end
  end

  desc "Sync Contacts"
  task :sync_contacts => :environment do
    system_task = SystemTask.create!(name: "stacks:sync_contacts")
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
      if e.try(:message).try(:start_with?, "809")
        system_task.mark_as_success
      elsif e.try(:message).try(:start_with?, "The maximum number of api calls allowed")
        system_task.mark_as_success
      else
        system_task.mark_as_error(e)
      end
    else
      system_task.mark_as_success
    end
  end

  desc "Daily Tasks"
  task :daily_tasks => :environment do
    system_task = SystemTask.create!(name: "stacks:daily_tasks")
    begin
      puts "~~~> DOING SYNC: #{Time.new.localtime}"
      # No dependencies, so we can do this first
      ProfitSharePass.ensure_exists!

      # These are all dependencies for the rest of the tasks
      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        Stacks::Team.discover!
      end
      Stacks::Forecast.new.sync_all! # Has internal retry counter
      Stacks::Runn.new.sync_all!

      Stacks::Quickbooks.sync_all! # Has internal retry counter

      # We can do this as soon as we sync the forecast
      Stacks::Automator.attempt_invoicing_for_previous_month
      Stacks::Automator.remind_people_to_record_hours_weekly

      # No dependencies, so we can do this next
      Stacks::Automator.remind_people_of_outstanding_surveys_every_thurday
      Stacks::Automator.send_project_capsule_reminders_every_tuesday

      # This one is quick, so we can do it next
      AdminUser.all.each(&:sync_salary_windows!)

      # This one takes about ~5 - 10 minutes to run
      Parallel.map(ForecastPerson.all, in_threads: 10) { |fp| fp.sync_utilization_reports! }

      puts "~~~> DOING SNAPSHOTS"
      Parallel.map(ProjectTracker.all, in_threads: 10) { |pt| pt.generate_snapshot! }

      # Do internal studios first, because their costs are absorbed by client_services studios
      Parallel.map(Studio.internal, in_threads: 2) { |s| s.generate_snapshot! }
      # Next, do reinvestment studios
      Parallel.map(Studio.reinvestment, in_threads: 3) { |s| s.generate_snapshot! }
      # Finally, do client_services, which require data from internal studios
      # (and garden3d hides reinvestment data)
      Parallel.map(Studio.client_services, in_threads: 3) { |s| s.generate_snapshot! }
      # Now, generate project snapshots
      Stacks::DailyFinancialSnapshotter.snapshot_all!

      puts "~~~> DOING MISC"
      Stacks::Dei.make_rollup # TODO Remove me

      Stacks::Notifications.make_notifications!
      Stacks::Notifications.notify_admins_of_outstanding_notifications_every_tuesday!

      runn_instance = Stacks::Runn.new
      ProjectTracker.where.not(runn_project: nil).each do |pt|
        puts "~~~> Will sync '#{pt.name}' Forecast Assignments to '#{pt.runn_project.name}' Runn Actuals"
        ProjectTrackerForecastToRunnSyncTask.create!(project_tracker: pt).run!(runn_instance)
        puts "~~~> Did sync '#{pt.name}' Forecast Assignments to '#{pt.runn_project.name}' Runn Actuals"
      end

      puts "~~~> FIN: #{Time.new.localtime}"
    rescue => e
      puts "~~~> ERROR"
      puts e
      puts e.backtrace

      system_task.mark_as_error(e)
    else
      system_task.mark_as_success
    end
  end
end
