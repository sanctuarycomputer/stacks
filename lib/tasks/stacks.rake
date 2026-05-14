namespace :stacks do
  desc "Freshen Qbo Token"
  task :refresh_qbo_token => :environment do
    system_task = SystemTask.create!(name: "stacks:refresh_qbo_token")
    begin
      Enterprise.sanctuary.qbo_account.make_and_refresh_qbo_access_token
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
      # Step 1: proactively refresh every enterprise's QBO token so
      # downstream steps aren't racing the 10-minute staleness gate or
      # surprise-401-ing mid-job. Per-enterprise failures are isolated and
      # only logged — downstream steps continue regardless (a stale token
      # will surface as an AuthorizationFailure inside sync_all! /
      # generate_snapshot!, which are already isolated per-enterprise).
      refresh_results = QboTokens::RefreshAll.call
      failed_refreshes = refresh_results.reject(&:ok?)
      if failed_refreshes.any?
        Rails.logger.warn("[stacks:daily_enterprise_tasks] #{failed_refreshes.size}/#{refresh_results.size} QBO token refreshes failed: #{failed_refreshes.map { |r| "enterprise=#{r.qbo_account.enterprise_id}" }.join(', ')}")
      end

      Parallel.map(QboAccount.all, in_threads: 2) { |e| e.sync_all! }
      Parallel.map(Enterprise.all, in_threads: 2) { |e| e.generate_snapshot! }

      # Pre-create a Ledger for every (enterprise, contributor) pair so a
      # contributor can submit a reimbursement / receive a pay stub against
      # any enterprise without first needing a ledger to be lazily created.
      inserted_ledger_count = Ledger.ensure_all!
      Rails.logger.info("[stacks:daily_enterprise_tasks] Ledger.ensure_all! created #{inserted_ledger_count} ledger(s)")

      # Open the next pay cycle for each enterprise on cadence. Per-enterprise
      # errors are isolated; a partial failure raises an aggregate after the
      # loop so this SystemTask still records visibly, but successful cycles
      # are already persisted.
      opened_cycles = PayCycles::OpenScheduledCycles.call
      Rails.logger.info("[stacks:daily_enterprise_tasks] OpenScheduledCycles opened #{opened_cycles.size} cycle(s)")
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

  desc "Sync Contributor Bills"
  task :sync_contributor_qbo_bills => :environment do
    system_task = SystemTask.create!(name: "stacks:sync_contributor_qbo_bills")
    failures = []

    sync_record = ->(record) {
      begin
        record.sync_qbo_bill!
      rescue => e
        failures << { record: "#{record.class.name}##{record.id}", error: "#{e.class}: #{e.message}" }
        Rails.logger.error("sync_qbo_bill! failed for #{record.class.name}##{record.id}: #{e.class}: #{e.message}")
      ensure
        # Throttle below QBO's ~500 req/min limit. sync_qbo_bill! typically makes
        # 2 API calls per record (load + create/update), so 0.15s per record
        # caps effective rate around ~400 req/min with headroom.
        sleep(0.15)
      end
    }

    begin
      Contributor.find_each do |c|
        c.contributor_payouts.each(&sync_record)
        c.contributor_adjustments.each(&sync_record)
        c.profit_shares.each(&sync_record)
      end
      Trueup.find_each(&sync_record)
    rescue => e
      system_task.mark_as_error(e)
      next
    end

    puts "Completed with #{failures.length} failure(s)."
    failures.each { |f| puts "  #{f[:record]}: #{f[:error]}" }

    if failures.any?
      # Surface a summary on the exception so Stacks::Notifications.report_exception
      # (called inside mark_as_error) sends a Twist notification that actually
      # tells us what broke, not just "something did."
      summary = failures.first(10).map { |f| "#{f[:record]}: #{f[:error]}" }.join("\n")
      suffix = failures.length > 10 ? "\n…and #{failures.length - 10} more (see task output)" : ""
      message = "#{failures.length} record(s) failed during sync_contributor_qbo_bills:\n#{summary}#{suffix}"
      system_task.mark_as_error(RuntimeError.new(message))
    else
      system_task.mark_as_success
    end
  end

  desc "Sync Founder Trueups"
  task :sync_founder_trueups => :environment do
    system_task = SystemTask.create!(name: "stacks:sync_founder_trueups")
    begin
      Stacks::System.sync_founder_trueups!
    rescue => e
      system_task.mark_as_error(e)
    end
  end

  desc "Daily Tasks"
  task :daily_tasks => :environment do
    system_task = SystemTask.create!(name: "stacks:daily_tasks")
    begin
      puts "~~~> DOING SYNC: #{Time.new.localtime}"
      SystemTask.clean_up_old_tasks!


      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        Stacks::Team.discover!
      end

      Stacks::Forecast.new.sync_all! # Has internal retry counter

      Retriable.retriable(tries: 3, base_interval: 5, multiplier: 2, max_interval: 60) do
        Stacks::OptixSync.new(OptixOrganization.first).sync_all!
      end

      # We can do this as soon as we sync the forecast
      Stacks::Automator.attempt_invoicing_for_previous_month

      # These are all dependencies for the rest of the tasks
      Stacks::Runn.new.sync_all!
      Enterprise.sanctuary.qbo_account.sync_all! # Has internal retry counter
      Stacks::Deel.new.sync_all!

      puts "~~~> SYNC DEEL WITHDRAWAL STATUSES (DEEL)"
      Retriable.retriable(tries: 3, base_interval: 5, multiplier: 2, max_interval: 60) do
        DeelInvoiceAdjustments::BatchSyncFromDeel.run!
      end

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

      puts "~~~> DOING MISC"
      Stacks::Notifications.make_notifications!

      puts "~~~> WARMING TASK BUILDER CACHE"
      Stacks::TaskBuilder.new.refresh!

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
