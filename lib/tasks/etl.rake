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
        # Pass since to run AND track:false so the explicit backfill window isn't overridden
        # by (nor written back into) the ongoing single-user sync cursor.
        Stacks::Etl::Meet::Connector.new(admin_email: admin, mode: :drive)
                                    .run(since: days.days.ago, track: false)
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

    # Drive backfill covers the OLDER window (created up to OVERLAP_GUARD ago); the ongoing
    # Meet API sweep covers the recent window (since 10 days). The two windows deliberately
    # OVERLAP (7..10 days) so a meeting near the boundary can't slip through a timing gap.
    # That overlap is safe, not duplicative: MeetApiSource#normalize skips any transcript a
    # Drive Document already ingested (keyed on the shared Drive doc id) — no fragile merge.
    OVERLAP_GUARD_DAYS = 7

    desc 'Org-wide Drive backfill of Meet transcripts for ALL users (default 90 days, older window)'
    task :backfill_meet_all, [:days] => :environment do |_t, args|
      Stacks::Etl::Meet.sweep_all_users!(
        task_name: 'stacks:etl:backfill_meet_all',
        mode: :drive,
        since: (args[:days] || 90).to_i.days.ago,
        until_time: OVERLAP_GUARD_DAYS.days.ago
      )
      Stacks::Etl::Meet.sweep_all_users!(
        task_name: 'stacks:etl:backfill_gemini_notes_all',
        mode: :gemini_notes,
        since: (args[:days] || 90).to_i.days.ago,
        until_time: nil,
        parse_transcript: true
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

    desc 'Org-wide Gemini-notes sync for ALL users (recent window; default 10 days)'
    task :sync_gemini_notes_all, [:days] => :environment do |_t, args|
      Stacks::Etl::Meet.sweep_all_users!(
        task_name: 'stacks:etl:sync_gemini_notes_all',
        mode: :gemini_notes,
        since: (args[:days] || 10).to_i.days.ago,
        until_time: nil,
        parse_transcript: false
      )
    end

    # The nightly ETL entry point. Runs the ongoing sync for EVERY source; today that's
    # Meet transcripts + Gemini notes, but new sources (Notion, Gmail, …) get added here
    # so the Scheduler job never has to change. Each source is invoked independently so
    # one source failing doesn't stop the others.
    desc 'Nightly ETL sync across ALL sources (currently Meet transcripts + Gemini notes)'
    task sync_all: :environment do
      %w[stacks:etl:sync_meet_all stacks:etl:sync_gemini_notes_all].each do |task_name|
        Rake::Task[task_name].invoke
      rescue => e
        Rails.logger.error("stacks:etl:sync_all — #{task_name} failed: #{e.class}: #{e.message}")
      end
    end
  end
end
