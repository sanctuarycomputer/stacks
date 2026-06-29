namespace :stacks do
  namespace :etl do
    desc 'Ongoing Google Meet transcript sync (Meet REST API)'
    task sync_meet: :environment do
      system_task = SystemTask.create!(name: 'stacks:etl:sync_meet')
      begin
        admin = Stacks::Utils.config.dig(:google_oauth2, :admin_email) || 'hugh@sanctuary.computer'
        Stacks::Etl::Meet::Connector.new(admin_email: admin, mode: :api).run
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end

    desc 'Backfill Google Meet transcripts from Drive (default 90 days)'
    task :backfill_meet, [:days] => :environment do |_t, args|
      system_task = SystemTask.create!(name: 'stacks:etl:backfill_meet')
      begin
        days = (args[:days] || 90).to_i
        admin = Stacks::Utils.config.dig(:google_oauth2, :admin_email) || 'hugh@sanctuary.computer'
        Stacks::Etl::Meet::Connector.new(admin_email: admin, mode: :drive, since: days.days.ago).run
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end

    # --- Org-wide multi-user sweeps ---------------------------------------------
    # These impersonate EVERY active Workspace user, error-isolated (one user's
    # failure never aborts the run), deduped by the global conference-record / Drive-
    # doc IDs. Meant to run on a Performance dyno (the local embedding model needs RAM).

    # Drive backfill covers the OLDER window only (up to OVERLAP_GUARD ago); the ongoing
    # Meet API sweep covers the recent window. Partitioning the two by time is how we avoid
    # ingesting the same meeting twice — no fragile cross-source merge.
    OVERLAP_GUARD_DAYS = 7

    desc 'Org-wide Drive backfill of Meet transcripts for ALL users (default 90 days, older window)'
    task :backfill_meet_all, [:days] => :environment do |_t, args|
      Stacks::Etl::Meet.sweep_all_users!(
        task_name: 'stacks:etl:backfill_meet_all',
        mode: :drive,
        since: (args[:days] || 90).to_i.days.ago,
        until_time: OVERLAP_GUARD_DAYS.days.ago
      )
    end

    desc 'Org-wide ongoing Meet API sync for ALL users (recent window; default 10 days)'
    task :sync_meet_all, [:days] => :environment do |_t, args|
      Stacks::Etl::Meet.sweep_all_users!(
        task_name: 'stacks:etl:sync_meet_all',
        mode: :api,
        since: (args[:days] || 10).to_i.days.ago
      )
    end
  end
end
