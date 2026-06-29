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

      # Sync vendors per-account so the Contributor-edit dropdown can offer
      # mappings across every enterprise's QBO realm. sync_all! above only
      # syncs P&L reports; vendors are a separate fetch. Per-account
      # errors are isolated so a stale token on one realm doesn't block
      # the others.
      QboAccount.find_each do |qa|
        qa.sync_all_vendors!
      rescue => e
        Rails.logger.error("[stacks:daily_enterprise_tasks] sync_all_vendors! failed for qbo_account=#{qa.id} (#{qa.enterprise&.name}): #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end

      Parallel.map(Enterprise.all, in_threads: 2) { |e| e.generate_snapshot! }

      # Backfill any missing Contributor rows for active ForecastPersons
      # FIRST — Contributor.after_create cascades into Ledger.ensure_for_contributor!,
      # so each newly created Contributor lands all its (enterprise) ledgers in
      # the same pass. Without this, an admin or contractor who exists in
      # Forecast but hasn't been on an invoice yet would have no Contributor →
      # no ledgers anywhere, and couldn't file reimbursements / accept pay stubs.
      inserted_contributor_count = Contributor.ensure_all_for_forecast_people!
      Rails.logger.info("[stacks:daily_enterprise_tasks] Contributor.ensure_all_for_forecast_people! created #{inserted_contributor_count} contributor(s)")

      # Pre-create a Ledger for every (enterprise, contributor) pair so a
      # contributor can submit a reimbursement / receive a pay stub against
      # any enterprise without first needing a ledger to be lazily created.
      # Belt-and-suspenders against drift — typically inserts 0 rows once
      # ensure_all_for_forecast_people! and the after_create callbacks have
      # done their work.
      inserted_ledger_count = Ledger.ensure_all!
      Rails.logger.info("[stacks:daily_enterprise_tasks] Ledger.ensure_all! created #{inserted_ledger_count} ledger(s)")

      # Open the next pay cycle for each enterprise on cadence. Per-enterprise
      # errors are isolated; a partial failure raises an aggregate after the
      # loop so this SystemTask still records visibly, but successful cycles
      # are already persisted.
      opened_cycles = PayCycles::OpenScheduledCycles.call
      Rails.logger.info("[stacks:daily_enterprise_tasks] OpenScheduledCycles opened #{opened_cycles.size} cycle(s)")

      # Materialize any due RecurringLedgerAdjustments. Each row's
      # materialize! is transactional and self-advances next_due_on, so
      # the loop is idempotent across same-day reruns. Per-row errors are
      # isolated so one bad row doesn't block the rest.
      materialized = 0
      RecurringLedgerAdjustment.active.due.find_each do |rla|
        rla.materialize!
        materialized += 1
      rescue => e
        Rails.logger.error("[stacks:daily_enterprise_tasks] RecurringLedgerAdjustment ##{rla.id} materialize failed: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
      Rails.logger.info("[stacks:daily_enterprise_tasks] Materialized #{materialized} recurring ledger adjustment(s)")
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

  # One-off recovery for InvoiceTrackers whose qbo_invoice_id was nulled out
  # but whose corresponding QBO invoice is still alive in Sanctuary's QBO.
  #
  # The 18 (tracker_id, qbo_invoice_id) pairs below were derived by:
  #   1) restoring the May-1 prod backup into a sidecar DB and pulling each
  #      detached tracker's original qbo_invoice_id (15 hits — the May-13
  #      cross-realm sync! bug cohort, all internal-client trackers);
  #   2) probing Sanctuary's live qbo_invoices for any remaining detached
  #      tracker by (invoice_pass.invoice_month, forecast_client.name) and
  #      finding 3 more hits (Gnosis May-2022 + Mac Miller Nov/Dec-2025)
  #      whose detachment predates the backup but whose QBO invoices are
  #      still alive.
  #
  # The remaining 47 detached trackers had no matching live QBO invoice and
  # are intentionally left alone — they represent legitimately voided /
  # deleted QBO invoices over the years, plus the manual "we don't invoice
  # ourselves" pattern your team applied before InvoicePass#make_trackers!
  # was updated to filter internal clients automatically.
  #
  # Per row: tracker_id, expected qbo_invoice_id, expected forecast client
  # name (sanity check), expected invoice-pass month (sanity check).
  REATTACH_MAPPINGS = [
    { tracker_id: 226,  qbo_invoice_id: "12638", fc: "Gnosis",          month: "May 2022" },
    { tracker_id: 1031, qbo_invoice_id: "21848", fc: "Index Space LLC", month: "June 2025" },
    { tracker_id: 1064, qbo_invoice_id: "22271", fc: "Index Space LLC", month: "July 2025" },
    { tracker_id: 1130, qbo_invoice_id: "22653", fc: "Index Space LLC", month: "August 2025" },
    { tracker_id: 1169, qbo_invoice_id: "24906", fc: "Index Space LLC", month: "September 2025" },
    { tracker_id: 1198, qbo_invoice_id: "25073", fc: "Index Space LLC", month: "October 2025" },
    { tracker_id: 1234, qbo_invoice_id: "25433", fc: "Index Space LLC", month: "November 2025" },
    { tracker_id: 1246, qbo_invoice_id: "26348", fc: "Mac Miller",      month: "November 2025" },
    { tracker_id: 1263, qbo_invoice_id: "26354", fc: "Mac Miller",      month: "December 2025" },
    { tracker_id: 1267, qbo_invoice_id: "26047", fc: "Index Space LLC", month: "December 2025" },
    { tracker_id: 1366, qbo_invoice_id: "26862", fc: "garden3d",        month: "January 2026" },
    { tracker_id: 1369, qbo_invoice_id: "26613", fc: "Index Space LLC", month: "January 2026" },
    { tracker_id: 1397, qbo_invoice_id: "27005", fc: "Index Space LLC", month: "February 2026" },
    { tracker_id: 1399, qbo_invoice_id: "27291", fc: "garden3d",        month: "February 2026" },
    { tracker_id: 1431, qbo_invoice_id: "27666", fc: "Index Space LLC", month: "March 2026" },
    { tracker_id: 1432, qbo_invoice_id: "27904", fc: "garden3d",        month: "March 2026" },
    { tracker_id: 1498, qbo_invoice_id: "28520", fc: "garden3d",        month: "April 2026" },
    { tracker_id: 1504, qbo_invoice_id: "28311", fc: "Index Space LLC", month: "April 2026" },
  ].freeze

  # Run with dry_run=true (default) first to preview. Run with dry_run=false
  # to actually apply.
  desc "Reattach the 18 InvoiceTrackers detached by sync! / migration bugs"
  task :recover_detached_invoice_trackers, [:dry_run] => :environment do |_t, args|
    dry_run = args[:dry_run].to_s != "false"
    puts "[recover_detached_invoice_trackers] dry_run=#{dry_run}"

    sanctuary_qa = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME).qbo_account
    raise "Sanctuary has no qbo_account" if sanctuary_qa.nil?

    will_apply = []
    already_attached = []
    sanity_failed = []
    missing_invoice = []
    missing_tracker = []

    REATTACH_MAPPINGS.each do |m|
      t = InvoiceTracker.find_by(id: m[:tracker_id])
      if t.nil?
        missing_tracker << m
        next
      end

      # Skip rows that were already manually reattached.
      if t.qbo_invoice_id.present?
        already_attached << { mapping: m, tracker: t }
        next
      end

      # Sanity-check that the tracker still matches the (fc, month) we
      # captured at audit time — guards against ID reuse / data drift.
      fc_name = t.forecast_client&.name
      month = t.invoice_pass&.invoice_month
      if fc_name != m[:fc] || month != m[:month]
        sanity_failed << { mapping: m, actual_fc: fc_name, actual_month: month }
        next
      end

      # Ensure the target QboInvoice row exists in Sanctuary's qa — without
      # it, attaching would point at a row this DB doesn't have, and
      # tracker.qbo_invoice would return nil anyway.
      inv = QboInvoice.find_by(qbo_id: m[:qbo_invoice_id], qbo_account_id: sanctuary_qa.id)
      if inv.nil?
        missing_invoice << m
        next
      end

      will_apply << { mapping: m, tracker: t, invoice: inv }
    end

    puts ""
    puts "Plan:"
    puts "  will reattach:       #{will_apply.size}"
    puts "  already attached:    #{already_attached.size}"
    puts "  sanity-check failed: #{sanity_failed.size}"
    puts "  invoice not in DB:   #{missing_invoice.size}"
    puts "  tracker not in DB:   #{missing_tracker.size}"

    if will_apply.any?
      puts ""
      puts "Will reattach:"
      will_apply.each do |row|
        m = row[:mapping]
        amount = row[:invoice].data&.dig("total")
        puts "  tracker=#{m[:tracker_id]} (#{m[:fc]} / #{m[:month]})  ->  qbo_invoice_id=#{m[:qbo_invoice_id]}  (invoice total $#{amount})"
      end
    end

    if already_attached.any?
      puts ""
      puts "Already attached (skipping):"
      already_attached.each do |row|
        puts "  tracker=#{row[:mapping][:tracker_id]}  current qbo_invoice_id=#{row[:tracker].qbo_invoice_id.inspect}"
      end
    end

    if sanity_failed.any?
      puts ""
      puts "Sanity-check failed (skipping — manual review):"
      sanity_failed.each do |row|
        puts "  tracker=#{row[:mapping][:tracker_id]} expected fc=#{row[:mapping][:fc].inspect} month=#{row[:mapping][:month].inspect}  got fc=#{row[:actual_fc].inspect} month=#{row[:actual_month].inspect}"
      end
    end

    if missing_invoice.any?
      puts ""
      puts "Target QboInvoice missing from Sanctuary's local mirror — run sanctuary_qa.sync_all_invoices! first:"
      missing_invoice.each do |m|
        puts "  tracker=#{m[:tracker_id]} expected qbo_invoice_id=#{m[:qbo_invoice_id].inspect}"
      end
    end

    if missing_tracker.any?
      puts ""
      puts "Tracker row missing entirely (skipping):"
      missing_tracker.each { |m| puts "  tracker_id=#{m[:tracker_id]}" }
    end

    if dry_run
      puts ""
      puts "[dry-run] no changes applied. Re-run with dry_run=false to apply."
      next
    end

    if will_apply.empty?
      puts ""
      puts "Nothing to apply."
      next
    end

    puts ""
    puts "Applying #{will_apply.size} reattachments…"
    applied = 0
    will_apply.each do |row|
      ActiveRecord::Base.transaction do
        row[:tracker].update_columns(qbo_invoice_id: row[:mapping][:qbo_invoice_id])
      end
      applied += 1
    end
    puts "Done. Reattached #{applied} trackers."
  end

  # Read-only diagnostic for the Stacks::Errors::Base "Failed Runn sync"
  # exception that ProjectTrackerForecastToRunnSyncTask#sync! raises when
  # project_tracker.lifetime_value disagrees with the Runn revenue
  # calculated from current actuals.
  #
  # Usage:
  #   rake stacks:diagnose_runn_sync[27]         # fetch fresh from Runn
  #   rake stacks:diagnose_runn_sync[27,true]    # use cached tmp/runn_sync_pt_27.json
  desc "Diagnose Runn ↔ Project-Tracker LTV mismatch for a project_tracker"
  task :diagnose_runn_sync, [:project_tracker_id, :cache] => :environment do |_t, args|
    require "stacks/runn_sync_diagnostic"

    pt_id = args[:project_tracker_id].to_i
    raise "Pass a project_tracker_id: rake 'stacks:diagnose_runn_sync[27]'" if pt_id.zero?

    pt = ProjectTracker.find(pt_id)
    raise "ProjectTracker #{pt_id} has no associated runn_project" if pt.runn_project.nil?

    use_cache = args[:cache].to_s == "true"
    cache_path = Rails.root.join("tmp", "runn_sync_pt_#{pt_id}.json")

    if use_cache && cache_path.exist?
      cached = JSON.parse(cache_path.read)
      runn_actuals = cached["actuals"]
      runn_roles = cached["roles"]
      puts "Loaded cached Runn data from #{cache_path}"
    else
      runn = Stacks::Runn.new
      puts "Fetching Runn actuals (project runn_id=#{pt.runn_project.runn_id})…"
      runn_actuals = runn.get_actuals_for_project(pt.runn_project.runn_id)
      puts "  got #{runn_actuals.size} actuals"
      puts "Fetching Runn roles…"
      runn_roles = runn.get_roles
      puts "  got #{runn_roles.size} roles"
      FileUtils.mkdir_p(cache_path.dirname)
      File.write(cache_path, JSON.dump("actuals" => runn_actuals, "roles" => runn_roles))
      puts "Cached Runn data to #{cache_path} (re-run with cache=true to skip the API hit)"
      puts ""
    end

    Stacks::RunnSyncDiagnostic.new(pt, runn_actuals: runn_actuals, runn_roles: runn_roles).report!
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

    accounts_cache = Qbo::AccountsCache.new
    sync_record = ->(record) {
      begin
        record.sync_qbo_bill!(accounts_cache: accounts_cache)
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
        c.reimbursements.where.not(accepted_at: nil).each(&sync_record)
      end
      Trueup.find_each(&sync_record)
      PayStub.where.not(accepted_at: nil).find_each(&sync_record)
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
